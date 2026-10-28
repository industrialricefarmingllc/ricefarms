#!/usr/bin/env python3
"""Persistent translation worker for the quick-translate widget.

A fresh HTTPS connection to opencode.ai costs ~3.7s on this machine, while a
reused one answers a translation in ~1.3-1.5s. This process therefore keeps one
Responses API connection open, preconnects at startup, and reads one JSON
request per stdin line:

  {"id": 1, "prompt": "...", "model": "gpt-6-luna", "effort": "none"}
  {"id": 1, "prompt": "...", "image_path": "/path/to/image", "model": "gpt-6-luna", "effort": "none"}
  {"warm": true}

and writes one JSON line per result:

  {"id": 1, "text": "...", "usage": {...}, "latency_ms": 1500}
  {"ready": true}

The OpenCode Go credential arrives in QUICK_TRANSLATE_KEY; it is never written
to disk or put on a command line.
"""

import base64
import http.client
import io
import json
import os
import select
import socket
import ssl
import sys
import time

ENDPOINT = "/inference/go/openai/v1/responses"
HOST = "opencode.ai"
KEY = os.environ.get("QUICK_TRANSLATE_KEY", "").strip()
MAX_IMAGE_SIDE = 1280

# The host resolves to IPv6 first here, while the route is IPv4 only. urllib and
# http.client then fail with "Network is unreachable" instead of falling back.
_orig_getaddrinfo = socket.getaddrinfo


def _ipv4_getaddrinfo(*args, **kwargs):
    return [entry for entry in _orig_getaddrinfo(*args, **kwargs) if entry[0] == socket.AF_INET]


socket.getaddrinfo = _ipv4_getaddrinfo

_conn = None


class ProviderError(Exception):
    pass


def close_conn():
    global _conn
    if _conn is not None:
        try:
            _conn.close()
        except Exception:
            pass
    _conn = None


def connection_alive():
    if _conn is None or _conn.sock is None:
        return False
    try:
        readable, _, _ = select.select([_conn.sock], [], [], 0)
        if not readable:
            return True
        # no unsolicited data is expected on this protocol, so readable means
        # the server has closed the keep-alive connection
        return False
    except Exception:
        return False


def ensure_conn():
    global _conn
    if connection_alive():
        return
    close_conn()
    _conn = http.client.HTTPSConnection(
        HOST,
        timeout=55,
        context=ssl.create_default_context(),
    )
    _conn.connect()
    try:
        _conn.sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except Exception:
        pass


def emit(data):
    sys.stdout.write(json.dumps(data, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def image_data_url(path):
    """Resize the actual image to a 1280px longest side, preserving aspect."""
    try:
        from PIL import Image, ImageOps
    except Exception as exc:
        raise ProviderError("image support needs Pillow: %s" % exc)

    Image.MAX_IMAGE_PIXELS = 80_000_000
    try:
        with Image.open(path) as source:
            source.seek(0)
            image = ImageOps.exif_transpose(source)
            image.thumbnail((MAX_IMAGE_SIDE, MAX_IMAGE_SIDE), Image.Resampling.LANCZOS)
            if image.mode not in ("RGB", "RGBA"):
                has_alpha = "A" in image.getbands()
                image = image.convert("RGBA" if has_alpha else "RGB")
            out = io.BytesIO()
            image.save(out, format="PNG", optimize=True)
    except Exception as exc:
        raise ProviderError("could not read image: %s" % exc)

    return "data:image/png;base64," + base64.b64encode(out.getvalue()).decode("ascii")


def translate(prompt, model, effort, image_paths=None):
    if not KEY:
        raise ProviderError("no OpenCode Go credential")

    images = [image_data_url(path) for path in (image_paths or []) if path]
    content = [{"type": "input_text", "text": prompt}]
    for image in images:
        content.append({
            "type": "input_image",
            "image_url": image,
            "detail": "high",
        })

    body = json.dumps({
        "model": model,
        "input": [{
            # The prompt is instructions for text-only calls. With an image it
            # belongs on the user turn alongside the image part.
            "role": "user" if images else "system",
            "content": content,
        }],
        "reasoning": {
            "effort": effort,
            "summary": "auto",
        },
        "include": ["reasoning.encrypted_content"],
        "max_output_tokens": 8192 if images else 2048,
    }, ensure_ascii=False)

    headers = {
        "Authorization": "Bearer " + KEY,
        "Content-Type": "application/json",
        "User-Agent": "opencode/2.0.32",
        "x-opencode-session": "quick-translate",
        "Connection": "keep-alive",
    }

    last_error = None
    for attempt in range(2):
        try:
            ensure_conn()
            started = time.monotonic()
            _conn.request("POST", ENDPOINT, body=body.encode("utf-8"), headers=headers)
            response = _conn.getresponse()
            raw = response.read().decode("utf-8", "replace")
            elapsed = int((time.monotonic() - started) * 1000)

            if response.will_close:
                close_conn()

            if response.status != 200:
                detail = raw
                try:
                    parsed = json.loads(raw)
                    detail = (parsed.get("error") or {}).get("message") or parsed.get("message") or raw
                except ValueError:
                    pass
                raise ProviderError("HTTP %s: %s" % (response.status, str(detail).strip()[:800]))

            try:
                data = json.loads(raw)
            except ValueError:
                raise ProviderError("provider returned non-JSON")

            text = ""
            for item in data.get("output", []):
                if item.get("type") != "message":
                    continue
                for part in item.get("content", []):
                    if part.get("type") == "output_text":
                        text += part.get("text", "")

            if text.strip() == "":
                raise ProviderError("provider returned no text")

            return text, data.get("usage") or {}, elapsed
        except ProviderError:
            raise
        except Exception as exc:
            last_error = exc
            close_conn()
            if attempt == 0:
                continue
            raise ProviderError(str(exc))

    raise ProviderError(str(last_error or "request failed"))


def main():
    if not KEY:
        emit({"ready": False, "error": "no OpenCode Go credential"})
        return

    try:
        ensure_conn()
        emit({"ready": True})
    except Exception as exc:
        emit({"ready": False, "error": str(exc)})

    for line in sys.stdin:
        line = line.strip()
        if line == "":
            continue

        try:
            request = json.loads(line)
        except ValueError:
            emit({"error": "bad request JSON"})
            continue

        if request.get("warm"):
            try:
                ensure_conn()
                emit({"ready": True})
            except Exception as exc:
                emit({"ready": False, "error": str(exc)})
            continue

        request_id = request.get("id")
        prompt = str(request.get("prompt", "")).strip()
        if prompt == "":
            emit({"id": request_id, "error": "empty prompt"})
            continue

        image_path = str(request.get("image_path") or "").strip()
        image_paths = [image_path] if image_path else []

        try:
            text, usage, elapsed = translate(
                prompt,
                str(request.get("model") or "gpt-6-luna"),
                str(request.get("effort") or "none"),
                image_paths,
            )
            emit({
                "id": request_id,
                "text": text,
                "usage": usage,
                "latency_ms": elapsed,
            })
        except Exception as exc:
            emit({"id": request_id, "error": str(exc)})


if __name__ == "__main__":
    main()
