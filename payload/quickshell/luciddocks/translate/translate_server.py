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

The OpenCode Go credentials arrive in QUICK_TRANSLATE_KEYS (one per line, the
preferred key first) and QUICK_TRANSLATE_KEY (the first of them, for older
callers); they are never written to disk or put on a command line. Keys are
tried in order and the worker only moves to the next one when the provider
rejects the current credential, so the common path is still one request.
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
MAX_IMAGE_SIDE = 1280

# Statuses that mean "this particular credential is not usable right now" as
# opposed to "the request is wrong": revoked keys (401/403) and accounts over
# their usage limit (429). Only these trigger a switch to the next key.
ROTATE_STATUSES = (401, 402, 403, 429)


def load_keys():
    """Keys from QUICK_TRANSLATE_KEYS (newline separated), preferred one first.

    QUICK_TRANSLATE_KEY is still honoured so an older caller keeps working; it
    is only added when the list does not already contain it.
    """
    keys = []
    single = os.environ.get("QUICK_TRANSLATE_KEY", "").strip()
    if single:
        keys.append(single)
    for raw in os.environ.get("QUICK_TRANSLATE_KEYS", "").replace(",", "\n").splitlines():
        key = raw.strip()
        if key and key not in keys:
            keys.append(key)
    return keys


KEYS = load_keys()
_key_index = 0

# opencode.ai is served by Cloudflare and answers with several IPv4 and IPv6
# addresses. Pinning the resolver to one family (as an earlier IPv4-only hack
# did) turns a single unreachable anycast address into a hard "No route to
# host" (errno 113). Try every address instead and remember the last one that
# completed a handshake so reconnects go straight back to it.
_last_addr = None

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


def _addresses():
    """Every distinct (family, address) the host resolves to."""
    try:
        infos = socket.getaddrinfo(HOST, 443, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise ProviderError("cannot resolve %s: %s" % (HOST, exc))

    out, seen = [], set()
    for family, _, _, _, sockaddr in infos:
        key = (family, sockaddr[0])
        if key not in seen:
            seen.add(key)
            out.append(key)

    if _last_addr is not None:
        out.sort(key=lambda item: item != _last_addr)
    return out


def connect_socket(timeout):
    """TCP-connect to the first address that answers, IPv4 or IPv6."""
    global _last_addr
    last_error = None

    for family, ip in _addresses():
        sock = socket.socket(family, socket.SOCK_STREAM)
        # Keep a dead anycast address from eating the whole request budget.
        sock.settimeout(min(timeout, 8))
        try:
            sock.connect((ip, 443))
            _last_addr = (family, ip)
            return sock
        except OSError as exc:
            last_error = exc
            try:
                sock.close()
            except Exception:
                pass

    if last_error is not None:
        raise last_error
    raise ProviderError("no usable address for " + HOST)


def ensure_conn():
    global _conn
    if connection_alive():
        return
    close_conn()

    context = ssl.create_default_context()
    raw = connect_socket(55)
    try:
        sock = context.wrap_socket(raw, server_hostname=HOST)
    except Exception:
        try:
            raw.close()
        except Exception:
            pass
        raise

    conn = http.client.HTTPSConnection(HOST, timeout=55, context=context)
    conn.sock = sock
    try:
        conn.sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except Exception:
        pass
    _conn = conn


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


def error_detail(raw):
    try:
        parsed = json.loads(raw)
        return str((parsed.get("error") or {}).get("message") or parsed.get("message") or raw).strip()[:800]
    except ValueError:
        return str(raw).strip()[:800]


def post(key, body):
    """One request on the shared keep-alive connection, with the given key."""
    headers = {
        "Authorization": "Bearer " + key,
        "Content-Type": "application/json",
        "User-Agent": "opencode/2.0.32",
        "x-opencode-session": "quick-translate",
        "Connection": "keep-alive",
    }
    ensure_conn()
    started = time.monotonic()
    _conn.request("POST", ENDPOINT, body=body.encode("utf-8"), headers=headers)
    response = _conn.getresponse()
    raw = response.read().decode("utf-8", "replace")
    elapsed = int((time.monotonic() - started) * 1000)
    if response.will_close:
        close_conn()
    return response.status, raw, elapsed


def post_with_retry(key, body):
    """Retry once on a transport error; a dead socket is not a key problem."""
    last_error = None
    for attempt in range(2):
        try:
            return post(key, body)
        except Exception as exc:
            last_error = exc
            close_conn()
    raise ProviderError(str(last_error or "request failed"))


def translate(prompt, model, effort, image_paths=None):
    global _key_index
    if not KEYS:
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

    # Start on the key that worked last. A healthy key means exactly one
    # request; the other keys are only touched when the provider rejects it.
    last_error = None
    for _ in range(len(KEYS)):
        status, raw, elapsed = post_with_retry(KEYS[_key_index], body)

        if status in ROTATE_STATUSES:
            last_error = ProviderError("HTTP %s: %s" % (status, error_detail(raw)))
            # Stay on the next candidate for subsequent messages too.
            _key_index = (_key_index + 1) % len(KEYS)
            continue

        if status != 200:
            raise ProviderError("HTTP %s: %s" % (status, error_detail(raw)))

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

    raise ProviderError(str(last_error or "request failed"))


def main():
    if not KEYS:
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
