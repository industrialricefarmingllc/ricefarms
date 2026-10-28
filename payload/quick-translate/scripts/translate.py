#!/usr/bin/env python3
"""One-shot diagnostic translation through the OpenCode Go provider.

The widget itself uses scripts/translate_server.py, which keeps the TLS
connection open. This script is for checking the provider/usage by hand.

The widget reads this credential from the local OpenCode service and passes it
in QUICK_TRANSLATE_KEY; it is never written to disk or put on a command line.
Requests use the Responses API, the same endpoint the OpenCode service uses,
with reasoning effort "none" unless the widget asks for another variant.

stdin:  {"prompt": "...", "model": "gpt-6-luna", "effort": "none"}
stdout: {"text": "...", "usage": {...}, "latency_ms": 1234}
"""

import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = "https://opencode.ai/inference/go/openai/v1/responses"

# This host resolves to IPv6 first on some systems, while the route is IPv4
# only. urllib then fails with "Network is unreachable" instead of falling
# back, so keep address resolution on IPv4.
_orig_getaddrinfo = socket.getaddrinfo


def _ipv4_getaddrinfo(*args, **kwargs):
    return [entry for entry in _orig_getaddrinfo(*args, **kwargs) if entry[0] == socket.AF_INET]


socket.getaddrinfo = _ipv4_getaddrinfo


def fail(message):
    print(str(message).strip()[:2000], file=sys.stderr)
    raise SystemExit(1)


def main():
    try:
        request = json.loads(sys.stdin.read() or "{}")
    except ValueError as exc:
        fail("translate.py: bad request JSON: %s" % exc)

    prompt = str(request.get("prompt", "")).strip()
    if not prompt:
        fail("translate.py: empty prompt")

    key = os.environ.get("QUICK_TRANSLATE_KEY", "").strip()
    if not key:
        fail("translate.py: no OpenCode Go credential")

    payload = {
        "model": str(request.get("model") or "gpt-6-luna"),
        "input": [{
            "role": "system",
            "content": [{"type": "input_text", "text": prompt}],
        }],
        "reasoning": {
            "effort": str(request.get("effort") or "none"),
            "summary": "auto",
        },
        "include": ["reasoning.encrypted_content"],
        "max_output_tokens": 2048,
    }

    headers = {
        "Authorization": "Bearer " + key,
        "Content-Type": "application/json",
        # the provider routes Go requests by session header and rejects the
        # default Python agent, so identify as the same client the CLI uses
        "User-Agent": "opencode/2.0.32",
        "x-opencode-session": "quick-translate",
    }

    http_request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
    )

    started = time.monotonic()
    try:
        with urllib.request.urlopen(http_request, timeout=55) as response:
            raw = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        detail = body
        try:
            parsed = json.loads(body)
            detail = (parsed.get("error") or {}).get("message") or parsed.get("message") or body
        except ValueError:
            pass
        fail("translate.py: HTTP %s: %s" % (exc.code, detail))
    except Exception as exc:
        fail("translate.py: %s" % exc)

    elapsed = int((time.monotonic() - started) * 1000)

    try:
        data = json.loads(raw)
    except ValueError:
        fail("translate.py: provider returned non-JSON")

    text = ""
    for item in data.get("output", []):
        if item.get("type") != "message":
            continue
        for part in item.get("content", []):
            if part.get("type") == "output_text":
                text += part.get("text", "")

    if text.strip() == "":
        fail("translate.py: provider returned no text")

    print(json.dumps({
        "text": text,
        "usage": data.get("usage") or {},
        "latency_ms": elapsed,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
