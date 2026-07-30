#!/usr/bin/env python3
"""MCP server for remote llm-server model switching, status, and lifecycle.

Transport: Streamable HTTP (JSON-RPC over HTTP) mounted at /mcp. It listens on the
Windows host (default 127.0.0.1:8901). Remote clients never talk to it directly -
the gateway proxy on :8899 reverse-proxies /mcp -> here, so one WAN port + one
bearer key covers inference and MCP.

    client ──▶ gateway :8899 /mcp ──▶ mcp/server.py :8901 (Windows host)
                                                    │
                                                    └── host_controller :8900 /admin/*

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


# The MCP server calls the host controller directly on :8900.
HOST_CONTROLLER_URL = (
    os.environ.get("HOST_CONTROLLER_URL") or "http://127.0.0.1:8900"
).rstrip("/")

# Gateway proxy for LLM health checks (llama.cpp is not exposed on host).
GATEWAY_URL = (
    os.environ.get("LLM_SERVER_URL") or "http://127.0.0.1:8899"
).rstrip("/")

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


def _request(
    method: str, path: str, *, json_body: dict[str, Any] | None = None, timeout: float = 30.0
) -> dict[str, Any]:
    url = f"{HOST_CONTROLLER_URL}{path}"
    with httpx.Client(timeout=timeout) as client:
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


def _llm_health() -> dict[str, Any]:
    """Check llama.cpp health through the gateway proxy."""
    try:
        with httpx.Client(timeout=5.0) as client:
            resp = client.get(f"{GATEWAY_URL}/health", headers=_headers())
        return {"healthy": resp.status_code == 200, "status_code": resp.status_code}
    except Exception as exc:
        return {"healthy": False, "error": str(exc)}


def _wait_for_ready() -> dict[str, Any]:
    deadline = time.time() + POLL_TIMEOUT
    last: dict[str, Any] = {}
    while time.time() < deadline:
        last = _request("GET", "/admin/status")
        runtime = last.get("runtime") or {}
        job = last.get("job") or {}

        if runtime.get("status") == "ready":
            llm = _llm_health()
            if llm.get("healthy"):
                last["llm"] = llm
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
    data["llm"] = _llm_health()
    return json.dumps(data, indent=2)


@mcp.tool()
def switch_model(
    model: str,
    context: int | None = None,
    thinking: bool | None = None,
    wait: bool = True,
    cancel: bool = True,
) -> str:
    """Switch the loaded GGUF model on the Windows host (qwen36, heretic, qwen35-9b, or qwen35-4b).

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


@mcp.tool()
def start_server(model: str | None = None, context: int | None = None) -> str:
    """Start the llm-server stack (docker compose up with the specified model).

    If no model is given, uses the last active model or defaults to qwen36.
    Returns immediately after the job is accepted; use get_server_status to poll.
    """
    body: dict[str, Any] = {"cancel": True}
    if model:
        body["model"] = model
    if context is not None:
        body["context"] = context

    result = _request("POST", "/admin/start", json_body=body)
    return json.dumps(result, indent=2)


@mcp.tool()
def stop_server() -> str:
    """Stop the llm-server stack (docker compose down).

    Shuts down the llama.cpp and gateway containers.
    """
    result = _request("POST", "/admin/stop", timeout=90.0)
    return json.dumps(result, indent=2)


@mcp.tool()
def list_tools() -> str:
    """List all available MCP tools on this server with their descriptions."""
    tools = [
        {"name": "list_tools", "description": "List all available MCP tools on this server with their descriptions."},
        {"name": "list_models", "description": "List switchable model aliases (qwen36, heretic, qwen35-9b, qwen35-4b)."},
        {"name": "get_server_status", "description": "Get current model, runtime state, job status, and llama.cpp health."},
        {"name": "switch_model", "description": "Switch the loaded GGUF model. Params: model (required), context, thinking, wait, cancel."},
        {"name": "start_server", "description": "Start the llm-server stack (docker compose up). Params: model (optional), context."},
        {"name": "stop_server", "description": "Stop the llm-server stack (docker compose down)."},
    ]
    return json.dumps({"tools": tools, "count": len(tools)}, indent=2)


@mcp.custom_route("/health", methods=["GET"])
async def health(_request: Request) -> JSONResponse:
    """Liveness probe used by run.ps1 when auto-starting this server."""
    return JSONResponse({"status": "ok"})


if __name__ == "__main__":
    transport = "stdio" if MCP_TRANSPORT == "stdio" else "streamable-http"
    if transport == "streamable-http":
        print(f"llm-server MCP (streamable-http) on http://{MCP_HOST}:{MCP_PORT}/mcp")
        print(f"Host controller: {HOST_CONTROLLER_URL}")
        print(f"Gateway: {GATEWAY_URL}")
        print(f"Admin auth: {'ENABLED' if ADMIN_KEY else 'disabled (open)'}")
    mcp.run(transport=transport)
