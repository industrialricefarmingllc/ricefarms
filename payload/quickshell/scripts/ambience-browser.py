#!/usr/bin/env python3
# usage: ambience-browser.py
#
# Inspect the browser's DevTools targets once a second and print one of:
#   pwa          only a YouTube Music page is playing
#   other        a browser page other than YouTube Music is playing
#   both         both kinds are playing
#   none         targets were readable but nothing is playing
#   unavailable  the debugging endpoint could not be read
#
# This is only a read-only media-element check. It lets the ambience tell the
# YouTube Music PWA apart from an ordinary browser tab, which share one audio
# client on PipeWire.

import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.parse
import urllib.request

ENDPOINT = "http://127.0.0.1:9222/json"
EXPR = ("JSON.stringify({url: location.href, playing: "
        "Array.from(document.querySelectorAll('audio,video')).some("
        "m => !m.paused && !m.ended && m.volume > 0 && !m.muted)})")


def targets():
    with urllib.request.urlopen(ENDPOINT, timeout=2) as response:
        return json.load(response)


def ws_connect(url):
    rest = url[5:]
    hostport, _, path = rest.partition("/")
    host, _, port = hostport.partition(":")
    port = int(port or 80)
    sock = socket.create_connection((host, port), timeout=1.5)
    sock.settimeout(1.5)
    key = base64.b64encode(os.urandom(16)).decode()
    request = ("GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (path, hostport, key))
    sock.sendall(request.encode())
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise OSError("closed during handshake")
        data += chunk
    if b" 101 " not in data.split(b"\r\n", 1)[0]:
        raise OSError("websocket handshake failed")
    return sock


def send_text(sock, text):
    payload = text.encode()
    header = bytearray([0x81])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", length)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", length)
    mask = os.urandom(4)
    header += mask
    sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def recv_frame(sock):
    head = sock.recv(2)
    if len(head) < 2:
        raise OSError("closed")
    first, second = head
    opcode = first & 0x0F
    masked = second & 0x80
    length = second & 0x7F
    if length == 126:
        length = struct.unpack(">H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", sock.recv(8))[0]
    mask = sock.recv(4) if masked else b""
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            break
        payload += chunk
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def evaluate(ws_url, expression):
    sock = ws_connect(ws_url)
    try:
        send_text(sock, json.dumps({
            "id": 1,
            "method": "Runtime.evaluate",
            "params": {"expression": expression, "returnByValue": True},
        }))
        while True:
            opcode, payload = recv_frame(sock)
            if opcode == 0x08:
                raise OSError("closed")
            if opcode != 0x01:
                continue
            message = json.loads(payload)
            if message.get("id") == 1:
                return message
    finally:
        try:
            sock.close()
        except OSError:
            pass


def state():
    try:
        pages = [t for t in targets() if t.get("type") == "page"]
    except Exception:
        return "unavailable"

    readable = False
    pwa = False
    other = False
    for page in pages:
        url = str(page.get("url", ""))
        if not url.startswith(("http://", "https://")):
            continue
        ws = page.get("webSocketDebuggerUrl")
        if not ws:
            continue
        try:
            result = evaluate(ws, EXPR)
            readable = True
            value = result.get("result", {}).get("result", {}).get("value", "")
            info = json.loads(value)
        except Exception:
            continue

        if not info.get("playing"):
            continue
        host = urllib.parse.urlparse(str(info.get("url", ""))).hostname or ""
        if host == "music.youtube.com" or host.endswith(".music.youtube.com"):
            pwa = True
        else:
            other = True

    if not readable:
        return "unavailable"
    if pwa and other:
        return "both"
    if pwa:
        return "pwa"
    if other:
        return "other"
    return "none"


def main():
    last = None
    while True:
        current = state()
        if current != last:
            print(current, flush=True)
            last = current
        time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
