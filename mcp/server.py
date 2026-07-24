#!/usr/bin/env python3
"""MCP server for remote llm-server model switching and status.

Transport: Streamable HTTP (JSON-RPC over HTTP) mounted at /mcp. It listens on the
Windows host (default 127.0.0.1:8901). Remote clients never talk to it directly -
the usage-tracker proxy on :8899 reverse-proxies /mcp -> here (same pattern it uses
for /admin/*), so one WAN port + one bearer key covers inference, admin, and MCP.

    client ──▶ usage-tracker :8899 /mcp ──▶ mcp/server.py :8901 (Windows host)
                                                    │
                                                    └── GET/POST /admin/* on :8899

run.ps1 auto-starts this alongside host_controller.py. Configure a remote client
(Cursor, Hermes, ...) with a URL instead of a stdio command:

    { "mcpServers": { "llm-server": {
        "url": "http://<host-ip>:8899/mcp",
        "headers": { "Authorization": "Bearer <LLAMA_ADMIN_KEY>" } } } }

Set MCP_TRANSPORT=stdio to fall back to the classic stdio transport (local only).
"""

from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent


def _read_dotenv(key: str) -> str:
    """Read a key from the repo .env (so the host process needs no exported env)."""
    env_file = REPO_ROOT / ".env"
    if not env_file.is_file():
        return ""
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.+?)\s*$")
    for line in env_file.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1).strip()
    return ""


# The MCP server calls the admin API through the proxy (:8899) so /admin/status
# includes llama.cpp health, which _wait_for_ready needs.
SERVER_URL = (os.environ.get("LLM_SERVER_URL") or "http://127.0.0.1:8899").rstrip("/")
ADMIN_KEY = (
    os.environ.get("LLAMA_ADMIN_KEY", "").strip()
    or os.environ.get("LLAMA_API_KEY", "").strip()
    or _read_dotenv("LLAMA_ADMIN_KEY")
    or _read_dotenv("LLAMA_API_KEY")
)
POLL_INTERVAL = float(os.environ.get("LLM_SWITCH_POLL_INTERVAL", "5"))
POLL_TIMEOUT = float(os.environ.get("LLM_SWITCH_POLL_TIMEOUT", "600"))

MCP_HOST = os.environ.get("MCP_BIND_HOST", "127.0.0.1")
MCP_PORT = int(os.environ.get("MCP_BIND_PORT", "8901"))
MCP_TRANSPORT = (os.environ.get("MCP_TRANSPORT") or "streamable-http").strip()

mcp = FastMCP("llm-server", host=MCP_HOST, port=MCP_PORT)


def _headers() -> dict[str, str]:
    if not ADMIN_KEY:
        return {}
    return {"Authorization": f"Bearer {ADMIN_KEY}"}


def _request(method: str, path: str, *, json_body: dict[str, Any] | None = None) -> dict[str, Any]:
    url = f"{SERVER_URL}{path}"
    with httpx.Client(timeout=30.0) as client:
        if method == "GET":
            resp = client.get(url, headers=_headers())
        else:
            resp = client.post(url, headers=_headers(), json=json_body or {})
    try:
        payload = resp.json()
    except Exception:
        payload = {"raw": resp.text}
    if resp.status_code >= 400:
        raise RuntimeError(f"{method} {path} failed ({resp.status_code}): {payload}")
    return payload


def _wait_for_ready() -> dict[str, Any]:
    deadline = time.time() + POLL_TIMEOUT
    last: dict[str, Any] = {}
    while time.time() < deadline:
        last = _request("GET", "/admin/status")
        runtime = last.get("runtime") or {}
        job = last.get("job") or {}
        llm = last.get("llm") or {}

        if runtime.get("status") == "ready" and llm.get("healthy"):
            return last
        if job.get("status") == "failed":
            raise RuntimeError(f"Model switch failed: {job.get('error') or job}")
        if runtime.get("status") == "failed":
            raise RuntimeError(f"Model switch failed: {runtime.get('error') or runtime}")

        time.sleep(POLL_INTERVAL)

    raise TimeoutError(f"Model switch did not finish within {POLL_TIMEOUT}s. Last status: {last}")


@mcp.tool()
def list_models() -> str:
    """List switchable model aliases exposed by the llm-server admin API."""
    data = _request("GET", "/admin/models")
    return json.dumps(data, indent=2)


@mcp.tool()
def get_server_status() -> str:
    """Get current model runtime state, reconcile job status, and llama.cpp health."""
    data = _request("GET", "/admin/status")
    return json.dumps(data, indent=2)


@mcp.tool()
def switch_model(
    model: str,
    context: int | None = None,
    thinking: bool | None = None,
    wait: bool = True,
    cancel: bool = True,
) -> str:
    """Switch the loaded GGUF model on the Windows host (qwen36, heretic, or qwen35-9b).

    Cancels any in-flight reconcile by default, then re-runs run.ps1 with the
    requested model. Set wait=false to return immediately after the job is accepted.
    """
    body: dict[str, Any] = {"model": model, "cancel": cancel}
    if context is not None:
        body["context"] = context
    if thinking is not None:
        body["thinking"] = thinking

    accepted = _request("POST", "/admin/reconcile", json_body=body)
    if not wait:
        return json.dumps(accepted, indent=2)

    final = _wait_for_ready()
    return json.dumps({"accepted": accepted, "final": final}, indent=2)


@mcp.custom_route("/health", methods=["GET"])
async def health(_request: Request) -> JSONResponse:
    """Liveness probe used by run.ps1 when auto-starting this server."""
    return JSONResponse({"status": "ok"})


if __name__ == "__main__":
    transport = "stdio" if MCP_TRANSPORT == "stdio" else "streamable-http"
    if transport == "streamable-http":
        print(f"llm-server MCP (streamable-http) on http://{MCP_HOST}:{MCP_PORT}/mcp")
        print(f"Admin API target: {SERVER_URL}")
        print(f"Admin auth: {'ENABLED' if ADMIN_KEY else 'disabled (open)'}")
    mcp.run(transport=transport)
