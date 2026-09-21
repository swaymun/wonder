#!/usr/bin/env python3
"""Offline smoke: real code-mode JavaScript execution and nested tool round trip.

Uses the pinned Codex V1 length-prefixed stdio protocol; no model or API call.
"""
import json
import os
import select
import struct
import subprocess
import sys
import time


def main():
    process = subprocess.Popen([sys.argv[1], "--listen", "stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 20

    def send(value):
        data = json.dumps(value).encode()
        process.stdin.write(struct.pack("<I", len(data)) + data)
        process.stdin.flush()

    def read_exact(count):
        data = b""
        while len(data) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise RuntimeError("Code-mode host timed out")
            chunk = os.read(process.stdout.fileno(), count - len(data))
            if not chunk:
                raise RuntimeError("Code-mode host closed unexpectedly")
            data += chunk
        return data

    def receive():
        size = struct.unpack("<I", read_exact(4))[0]
        assert size <= 64 * 1024 * 1024
        return json.loads(read_exact(size))

    try:
        send({"type": "connection/hello", "supportedVersions": [1], "requiredCapabilities": [], "optionalCapabilities": []})
        assert receive()["type"] == "connection/ready"
        send({"type": "operation/request", "id": 1, "request": {"method": "session/open", "sessionId": "wonder-smoke"}})
        ready = receive()
        assert ready["result"]["value"]["type"] == "session/ready", ready
        send({"type": "operation/request", "id": 2, "request": {"method": "session/execute", "sessionId": "wonder-smoke", "request": {
            "tool_call_id": "smoke", "enabled_tools": [{"name": "ping", "tool_name": {"name": "ping", "namespace": None}, "description": "Offline test", "kind": "function", "input_schema": {"type": "object"}, "output_schema": None}],
            "source": "text(6 * 7); text(await tools.ping({value: 'wonder'}));", "yield_time_ms": 10000, "max_output_tokens": 1000}}})
        delegated = False
        while True:
            item = receive()
            if item["type"] == "delegate/request":
                invocation = item["request"]["invocation"]
                assert invocation["tool_name"]["name"] == "ping", invocation
                assert invocation["input"] == {"value": "wonder"}, invocation
                delegated = True
                send({"type": "delegate/response", "id": item["id"], "result": {"status": "ok", "value": {"type": "tool/result", "result": "round-trip-ok"}}})
            elif item["type"] == "execute/initialResponse":
                rendered = json.dumps(item)
                assert delegated and '42' in rendered and 'round-trip-ok' in rendered, item
                assert item["result"]["status"] == "ok", item
                print("PASS: JavaScript arithmetic and nested tool round trip")
                break
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()
