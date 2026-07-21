#!/usr/bin/env python3
"""MCP server for remote llm-server model switching and status."""

from __future__ import annotations

import json
import os
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

SERVER_URL = os.environ.get("LLM_SERVER_URL", "http://127.0.0.1:8899").rstrip("/")
ADMIN_KEY = os.environ.get("LLAMA_ADMIN_KEY", "").strip() or os.environ.get("LLAMA_API_KEY", "").strip()
POLL_INTERVAL = float(os.environ.get("LLM_SWITCH_POLL_INTERVAL", "5"))
POLL_TIMEOUT = float(os.environ.get("LLM_SWITCH_POLL_TIMEOUT", "600"))

mcp = FastMCP("llm-server")


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
    import time

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
    """Switch the loaded GGUF model on the Windows host (qwen36 or qwen35-9b).

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


if __name__ == "__main__":
    mcp.run()
