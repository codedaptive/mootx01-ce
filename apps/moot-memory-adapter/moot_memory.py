"""
MOOTx01 Memory Adapter — Anthropic memory_20250818 Python SDK handler.

Subclasses the Anthropic SDK's BetaAbstractMemoryTool (or works standalone)
to back the memory_20250818 tool contract with a governed MOOTx01 estate
via its MCP HTTP transport.

Usage with the SDK runner:
    from moot_memory import MootMemoryTool

    client = anthropic.Anthropic()
    memory = MootMemoryTool(base_url="http://127.0.0.1:4242")
    runner = client.beta.messages.tool_runner(
        model="claude-opus-4-8",
        max_tokens=1024,
        messages=[{"role": "user", "content": "Remember that..."}],
        tools=[memory],
    )
    final = runner.until_done()

Standalone usage (manual tool loop):
    handler = MootMemoryHandler(base_url="http://127.0.0.1:4242")
    result = handler.execute({"command": "view", "path": "/memories"})
"""

import json
import urllib.request
import urllib.error
from typing import Any, Optional

MEMORIES_ROOT = "/memories"
MAX_FILE_SIZE = 100 * 1024


class MootMemoryHandler:
    """Handles Anthropic memory_20250818 commands via MOOTx01 MCP HTTP."""

    def __init__(self, base_url: str = "http://127.0.0.1:4242"):
        self.base_url = base_url.rstrip("/")

    def execute(self, input_: dict[str, Any]) -> str:
        command = input_.get("command", "")
        dispatch = {
            "view": self._view,
            "create": self._create,
            "str_replace": self._str_replace,
            "insert": self._insert,
            "delete": self._delete,
            "rename": self._rename,
        }
        handler = dispatch.get(command)
        if handler is None:
            return f"Error: unknown command {command}"
        try:
            return handler(input_)
        except ValueError as e:
            return f"Error: {e}"

    # ── Commands ─────────────────────────────────────────────────────

    def _view(self, input_: dict) -> str:
        path = self._validate(input_.get("path", ""))
        if path == MEMORIES_ROOT or path == MEMORIES_ROOT + "/":
            return self._mcp("memory", {"command": "view", "path": path})
        return self._mcp("memory", {"command": "view", "path": path})

    def _create(self, input_: dict) -> str:
        path = self._validate(input_.get("path", ""))
        file_text = input_.get("file_text", "")
        if len(file_text.encode()) > MAX_FILE_SIZE:
            return f"Error: File content exceeds maximum size of {MAX_FILE_SIZE} bytes"
        return self._mcp("memory", {
            "command": "create", "path": path, "file_text": file_text
        })

    def _str_replace(self, input_: dict) -> str:
        path = self._validate(input_.get("path", ""))
        return self._mcp("memory", {
            "command": "str_replace", "path": path,
            "old_str": input_.get("old_str", ""),
            "new_str": input_.get("new_str", ""),
        })

    def _insert(self, input_: dict) -> str:
        path = self._validate(input_.get("path", ""))
        return self._mcp("memory", {
            "command": "insert", "path": path,
            "insert_line": input_.get("insert_line", 0),
            "insert_text": input_.get("insert_text", ""),
        })

    def _delete(self, input_: dict) -> str:
        path = self._validate(input_.get("path", ""))
        return self._mcp("memory", {"command": "delete", "path": path})

    def _rename(self, input_: dict) -> str:
        old = self._validate(input_.get("old_path", ""))
        new = self._validate(input_.get("new_path", ""))
        return self._mcp("memory", {
            "command": "rename", "old_path": old, "new_path": new
        })

    # ── Path validation ──────────────────────────────────────────────

    def _validate(self, path: str) -> str:
        if not path:
            raise ValueError("Empty path")
        if "%2e" in path.lower() or "%2f" in path.lower():
            raise ValueError(f"URL-encoded traversal: {path}")
        if ".." in path:
            raise ValueError(f"Path traversal: {path}")
        # Enforce a path-SEGMENT boundary, not a bare string prefix: a plain
        # startswith("/memories") also accepts siblings like "/memories2/x" or
        # "/memoriesxvictim.txt", which would forward outside the intended tree.
        if path != MEMORIES_ROOT and not path.startswith(MEMORIES_ROOT + "/"):
            raise ValueError(f"Must be {MEMORIES_ROOT} or start with {MEMORIES_ROOT}/: {path}")
        # No hidden files (README security policy): reject any dotfile component.
        if any(part.startswith(".") for part in path.split("/") if part):
            raise ValueError(f"Hidden path components not allowed: {path}")
        return path

    # ── MCP HTTP transport ───────────────────────────────────────────

    def _mcp(self, tool: str, args: dict) -> str:
        payload = json.dumps({
            "jsonrpc": "2.0", "id": 1,
            "method": "tools/call",
            "params": {"name": tool, "arguments": args},
        }).encode()
        req = urllib.request.Request(
            self.base_url, data=payload,
            headers={"Content-Type": "application/json", "Origin": "http://127.0.0.1"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read())
                content = body.get("result", {}).get("content", [])
                if content and isinstance(content, list):
                    return content[0].get("text", str(body))
                return str(body)
        except Exception as e:
            return f"Error: MCP call failed: {e}"


# ── SDK integration ──────────────────────────────────────────────────

try:
    from anthropic.tools import BetaAbstractMemoryTool

    class MootMemoryTool(BetaAbstractMemoryTool):
        """Drop-in replacement for BetaLocalFilesystemMemoryTool backed by MOOTx01."""

        def __init__(self, base_url: str = "http://127.0.0.1:4242"):
            self._handler = MootMemoryHandler(base_url=base_url)

        def view(self, path: str, view_range: Optional[list[int]] = None) -> str:
            args: dict[str, Any] = {"command": "view", "path": path}
            if view_range:
                args["view_range"] = view_range
            return self._handler.execute(args)

        def create(self, path: str, file_text: str) -> str:
            return self._handler.execute({
                "command": "create", "path": path, "file_text": file_text
            })

        def str_replace(self, path: str, old_str: str, new_str: Optional[str] = None) -> str:
            return self._handler.execute({
                "command": "str_replace", "path": path,
                "old_str": old_str, "new_str": new_str or "",
            })

        def insert(self, path: str, insert_line: int, insert_text: str) -> str:
            return self._handler.execute({
                "command": "insert", "path": path,
                "insert_line": insert_line, "insert_text": insert_text,
            })

        def delete(self, path: str) -> str:
            return self._handler.execute({"command": "delete", "path": path})

        def rename(self, old_path: str, new_path: str) -> str:
            return self._handler.execute({
                "command": "rename", "old_path": old_path, "new_path": new_path
            })

except ImportError:
    # anthropic SDK not installed — standalone handler still works
    pass
