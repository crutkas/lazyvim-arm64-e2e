#!/usr/bin/env python3
"""Exercise a complete LuaLS JSON-RPC lifecycle and retain the transcript."""

from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import threading
import time
from pathlib import Path
from typing import Any


def uri(path: Path) -> str:
    return path.resolve().as_uri()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=90)
    return parser.parse_args()


class Client:
    def __init__(self, command: list[str], cwd: Path) -> None:
        self.process = subprocess.Popen(
            command,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.messages: queue.Queue[dict[str, Any]] = queue.Queue()
        self.stderr: list[bytes] = []
        self.transcript: list[dict[str, Any]] = []
        self.reader = threading.Thread(target=self._read_messages, daemon=True)
        self.stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self.reader.start()
        self.stderr_reader.start()

    def _read_messages(self) -> None:
        assert self.process.stdout is not None
        stream = self.process.stdout
        while True:
            headers: dict[str, str] = {}
            while True:
                line = stream.readline()
                if not line:
                    return
                if line in (b"\r\n", b"\n"):
                    break
                key, _, value = line.decode("ascii", errors="replace").partition(":")
                headers[key.lower()] = value.strip()
            length = int(headers.get("content-length", "0"))
            body = stream.read(length)
            if len(body) != length:
                return
            message = json.loads(body.decode("utf-8"))
            self.transcript.append({"direction": "server-to-client", "message": message})
            self.messages.put(message)

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        while chunk := self.process.stderr.read(4096):
            self.stderr.append(chunk)

    def send(self, message: dict[str, Any]) -> None:
        body = json.dumps(message, separators=(",", ":")).encode("utf-8")
        framed = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body
        self.transcript.append({"direction": "client-to-server", "message": message})
        assert self.process.stdin is not None
        self.process.stdin.write(framed)
        self.process.stdin.flush()

    def wait_for_response(self, request_id: int, timeout: float, folder_uri: str) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty as error:
                raise TimeoutError(f"Timed out waiting for response {request_id}") from error
            if message.get("id") == request_id and ("result" in message or "error" in message):
                return message
            if "id" in message and "method" in message:
                method = message["method"]
                if method == "workspace/configuration":
                    result: Any = [{} for _ in message.get("params", {}).get("items", [])]
                elif method == "workspace/workspaceFolders":
                    result = [{"name": "lazyvim-e2e", "uri": folder_uri}]
                else:
                    result = None
                self.send({"jsonrpc": "2.0", "id": message["id"], "result": result})
        raise TimeoutError(f"Timed out waiting for response {request_id}")


def main() -> int:
    args = parse_args()
    started = time.perf_counter()
    result: dict[str, Any] = {
        "command": [str(args.server)],
        "file": str(args.file),
        "protocol": "LSP JSON-RPC 2.0",
        "success": False,
    }
    client: Client | None = None
    try:
        root_uri = uri(args.file.parent)
        file_uri = uri(args.file)
        client = Client([str(args.server)], args.file.parent)
        client.send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "capabilities": {
                        "textDocument": {"hover": {"contentFormat": ["markdown", "plaintext"]}},
                        "workspace": {"configuration": True, "workspaceFolders": True},
                    },
                    "clientInfo": {"name": "lazyvim-arm64-e2e", "version": "1"},
                    "processId": os.getpid(),
                    "rootUri": root_uri,
                    "workspaceFolders": [{"name": "lazyvim-e2e", "uri": root_uri}],
                },
            }
        )
        initialize = client.wait_for_response(1, args.timeout, root_uri)
        if "error" in initialize:
            raise RuntimeError(f"initialize failed: {initialize['error']}")
        client.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
        text = args.file.read_text(encoding="utf-8")
        client.send(
            {
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": {
                    "textDocument": {
                        "languageId": "lua",
                        "text": text,
                        "uri": file_uri,
                        "version": 1,
                    }
                },
            }
        )
        client.send(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "textDocument/hover",
                "params": {
                    "position": {"character": 8, "line": 0},
                    "textDocument": {"uri": file_uri},
                },
            }
        )
        hover = client.wait_for_response(2, args.timeout, root_uri)
        if "error" in hover:
            raise RuntimeError(f"hover failed: {hover['error']}")
        client.send({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": None})
        shutdown = client.wait_for_response(3, args.timeout, root_uri)
        if "error" in shutdown:
            raise RuntimeError(f"shutdown failed: {shutdown['error']}")
        client.send({"jsonrpc": "2.0", "method": "exit", "params": None})
        assert client.process.stdin is not None
        client.process.stdin.close()
        client.process.wait(timeout=15)
        result.update(
            {
                "exit_code": client.process.returncode,
                "hover_has_result": hover.get("result") is not None,
                "initialize_has_capabilities": bool(initialize.get("result", {}).get("capabilities")),
                "methods_sent": [
                    "initialize",
                    "initialized",
                    "textDocument/didOpen",
                    "textDocument/hover",
                    "shutdown",
                    "exit",
                ],
                "success": client.process.returncode == 0 and hover.get("result") is not None,
            }
        )
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
        if client and client.process.poll() is None:
            client.process.kill()
            client.process.wait(timeout=10)
    finally:
        if client:
            result["stderr"] = b"".join(client.stderr).decode("utf-8", errors="replace")
            result["transcript"] = client.transcript
        result["elapsed_seconds"] = time.perf_counter() - started
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
    return 0 if result["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
