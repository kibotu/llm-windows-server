#!/usr/bin/env python3
"""
Host-side control API for switching llm-server models on Windows.

This service runs outside Docker and invokes run.ps1 with the requested options.
"""

from __future__ import annotations

import json
import os
import queue
import re
import subprocess
import threading
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, Any, Generator, Optional
from datetime import datetime, timezone

import requests
from flask import Flask, Response, jsonify, request

app = Flask(__name__)

SCRIPT_DIR = Path(__file__).resolve().parent
RUN_SCRIPT = SCRIPT_DIR / "run.ps1"
MODELS_DIR = SCRIPT_DIR / "models"
USAGE_PROXY_BASE_URL = os.environ.get("USAGE_PROXY_BASE_URL", "http://localhost:8899")
LLM_HEALTH_URL = f"{USAGE_PROXY_BASE_URL}/health"
USAGE_HEALTH_URL = f"{USAGE_PROXY_BASE_URL}/usage"
ALLOWED_MODELS = {"9b", "qwen3uncensored8b", "35b", "qwen3635ba3b", "qwen3635ba3b2bit", "gemma312", "gemma426ba4b"}
ALLOWED_MOE_OFFLOAD = {"auto", "off", "all"}  # also accepts integers
ALLOWED_KV_CACHE = {"q4_0", "q8_0", "f16"}
CONTROL_PORT = int(os.environ.get("MODEL_SWITCHER_PORT", "8898"))


@dataclass
class SwitchState:
    in_progress: bool = False
    queued_model: str = "9b"
    queued_thinking: bool = False
    queued_restart: bool = True
    queued_moe_offload: str = "auto"
    queued_kv_cache: str = "q8_0"
    active_model: str = "9b"
    active_thinking: bool = False
    active_moe_offload: str = "auto"
    active_kv_cache: str = "q8_0"
    last_success: bool = False
    last_error: str = ""
    last_exit_code: Optional[int] = None
    last_completed_at: str = ""


state_lock = threading.Lock()
switch_lock = threading.Lock()
switch_state = SwitchState()


def add_cors_headers(response: Response) -> Response:
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response


def sse_event(event_type: str, payload: Dict[str, Any]) -> str:
    data = json.dumps(payload, ensure_ascii=True)
    return f"event: {event_type}\ndata: {data}\n\n"


def infer_available_models() -> Dict[str, bool]:
    available = {key: False for key in ALLOWED_MODELS}
    if not MODELS_DIR.exists():
        return available

    files = [entry.name for entry in MODELS_DIR.glob("*.gguf")]
    files_lower = [name.lower() for name in files]

    available["9b"] = any("9b" in name and "q4_k_m" in name for name in files_lower)
    available["qwen3uncensored8b"] = any("qwen3-8b-uncensor-v2" in name for name in files_lower)
    available["35b"] = any("35b-a3b" in name and ("q4_k_s" in name or "q4_k_xl" in name) for name in files_lower)
    available["qwen3635ba3b"] = any("qwen3.6-35b-a3b" in name and "q4_k_s" in name for name in files_lower)
    available["qwen3635ba3b2bit"] = any("qwen3.6-35b-a3b" in name and "q2_k" in name for name in files_lower)
    available["gemma312"] = any("gemma-3-12b-it-q4_k_m" in name for name in files_lower)
    available["gemma426ba4b"] = any("gemma-4-26b-a4b-it-ud-q4_k_m" in name for name in files_lower)
    return available


def get_server_health() -> Dict[str, Any]:
    usage_ok = False
    llm_ok = False
    usage_error = ""
    llm_error = ""

    try:
        usage_resp = requests.get(USAGE_HEALTH_URL, timeout=2)
        usage_ok = usage_resp.ok
    except Exception as exc:
        usage_error = str(exc)

    try:
        llm_resp = requests.get(LLM_HEALTH_URL, timeout=2)
        llm_ok = llm_resp.ok
    except Exception as exc:
        llm_error = str(exc)

    return {
        "usage_proxy_ok": usage_ok,
        "llm_ok": llm_ok,
        "usage_proxy_error": usage_error,
        "llm_error": llm_error,
    }


def get_live_model() -> str:
    try:
        resp = requests.get(f"{USAGE_PROXY_BASE_URL}/v1/models", timeout=2)
        if not resp.ok:
            return ""
        payload = resp.json()
        data = payload.get("data", [])
        if not data:
            return ""
        return str(data[0].get("id", ""))
    except Exception:
        return ""


def extract_last_nonempty_line(text: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def build_run_command(
    model: str,
    thinking: bool,
    restart: bool,
    moe_offload: str = "auto",
    kv_cache: str = "q8_0",
) -> list[str]:
    cmd = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(RUN_SCRIPT),
    ]
    if model:
        cmd.extend(["-Model", model])
    if thinking:
        cmd.append("-Thinking")
    if restart:
        cmd.append("-Restart")
    if moe_offload and moe_offload != "auto":
        cmd.extend(["-MoeOffload", moe_offload])
    if kv_cache and kv_cache != "q8_0":
        cmd.extend(["-KvCache", kv_cache])
    return cmd


def run_switch_and_stream(
    model: str,
    thinking: bool,
    restart: bool,
    moe_offload: str = "auto",
    kv_cache: str = "q8_0",
) -> Generator[str, None, None]:
    if not RUN_SCRIPT.exists():
        yield sse_event("error", {"message": f"Missing run script: {RUN_SCRIPT}"})
        yield sse_event("done", {"success": False})
        return

    got_lock = switch_lock.acquire(blocking=False)
    if not got_lock:
        yield sse_event("error", {"message": "Another switch is already running"})
        yield sse_event("done", {"success": False})
        return

    output_queue: queue.Queue[tuple[str, Optional[str]]] = queue.Queue()

    def emit_line(kind: str, line: Optional[str]) -> None:
        output_queue.put((kind, line))

    with state_lock:
        switch_state.in_progress = True
        switch_state.queued_model = model
        switch_state.queued_thinking = thinking
        switch_state.queued_restart = restart
        switch_state.queued_moe_offload = moe_offload
        switch_state.queued_kv_cache = kv_cache
        switch_state.last_error = ""

    def worker() -> None:
        cmd = build_run_command(model, thinking, restart, moe_offload, kv_cache)
        emit_line("status", f"Executing: {' '.join(cmd)}")
        server_ready = False
        collected_errors: list[str] = []

        try:
            process = subprocess.Popen(
                cmd,
                cwd=str(SCRIPT_DIR),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
        except Exception as exc:
            emit_line("fatal", f"Failed to start run.ps1: {exc}")
            with state_lock:
                switch_state.in_progress = False
                switch_state.last_success = False
                switch_state.last_error = str(exc)
                switch_state.last_exit_code = None
            switch_lock.release()
            output_queue.put(("done", None))
            return

        assert process.stdout is not None
        for raw in process.stdout:
            line = raw.rstrip()
            if not line:
                continue
            emit_line("output", line)
            lower = line.lower()
            if "server is ready!" in lower or "server running" in lower:
                server_ready = True
            if "!!" in line or "failed" in lower or "error" in lower:
                collected_errors.append(line)

        process.wait()
        exit_code = process.returncode
        success = exit_code == 0 and server_ready

        with state_lock:
            switch_state.in_progress = False
            switch_state.last_success = success
            switch_state.last_exit_code = exit_code
            switch_state.last_completed_at = datetime.now(timezone.utc).isoformat()
            if success:
                switch_state.active_model = model
                switch_state.active_thinking = thinking
                switch_state.active_moe_offload = moe_offload
                switch_state.active_kv_cache = kv_cache
                switch_state.last_error = ""
            else:
                switch_state.last_error = extract_last_nonempty_line("\n".join(collected_errors))

        switch_lock.release()
        output_queue.put(("done", None))

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()

    yield sse_event("status", {"phase": "starting", "message": "Switch request accepted"})
    while True:
        kind, line = output_queue.get()
        if kind == "done":
            break
        if kind == "fatal":
            yield sse_event("error", {"message": line})
            continue
        if kind == "status":
            yield sse_event("status", {"phase": "running", "message": line})
            continue

        assert line is not None
        progress = "running"
        if re.search(r"Restarting server", line, flags=re.IGNORECASE):
            progress = "restarting"
        elif re.search(r"Starting server", line, flags=re.IGNORECASE):
            progress = "starting"
        elif re.search(r"Waiting for server to be ready", line, flags=re.IGNORECASE):
            progress = "waiting"
        elif re.search(r"Server is ready", line, flags=re.IGNORECASE):
            progress = "ready"
        elif line.strip() == ".":
            progress = "loading"

        yield sse_event("output", {"phase": progress, "line": line})

    with state_lock:
        payload = {
            "success": switch_state.last_success,
            "model": switch_state.active_model if switch_state.last_success else model,
            "thinking": switch_state.active_thinking if switch_state.last_success else thinking,
            "moe_offload": switch_state.active_moe_offload if switch_state.last_success else moe_offload,
            "kv_cache": switch_state.active_kv_cache if switch_state.last_success else kv_cache,
            "exit_code": switch_state.last_exit_code,
            "error": switch_state.last_error,
        }
    yield sse_event("done", payload)


@app.route("/models", methods=["GET", "OPTIONS"])
@app.route("/models/", methods=["GET", "OPTIONS"])
def get_models() -> Response:
    if request.method == "OPTIONS":
        return add_cors_headers(Response(""))

    available = infer_available_models()
    live_model = get_live_model()
    with state_lock:
        state = asdict(switch_state)
    response = jsonify(
        {
            "available": available,
            "allowed_models": sorted(ALLOWED_MODELS),
            "live_model": live_model,
            "state": state,
        }
    )
    return add_cors_headers(response)


@app.route("/status", methods=["GET", "OPTIONS"])
@app.route("/status/", methods=["GET", "OPTIONS"])
def get_status() -> Response:
    if request.method == "OPTIONS":
        return add_cors_headers(Response(""))

    with state_lock:
        state = asdict(switch_state)
    health = get_server_health()
    live_model = get_live_model()
    response = jsonify({"state": state, "health": health, "live_model": live_model})
    return add_cors_headers(response)


@app.route("/switch", methods=["POST", "OPTIONS"])
@app.route("/switch/", methods=["POST", "OPTIONS"])
def switch_model() -> Response:
    if request.method == "OPTIONS":
        return add_cors_headers(Response(""))

    payload = request.get_json(silent=True) or {}
    model = str(payload.get("model", "9b")).strip()
    thinking = bool(payload.get("thinking", False))
    restart = bool(payload.get("restart", True))
    moe_offload = str(payload.get("moe_offload", "auto")).strip()
    kv_cache = str(payload.get("kv_cache", "q8_0")).strip()

    if model not in ALLOWED_MODELS:
        response = jsonify({"error": f"Invalid model '{model}'", "allowed_models": sorted(ALLOWED_MODELS)})
        response.status_code = 400
        return add_cors_headers(response)

    # Validate moe_offload: must be 'auto', 'off', 'all', or a positive integer
    if moe_offload not in ALLOWED_MOE_OFFLOAD:
        if not moe_offload.isdigit():
            response = jsonify({
                "error": f"Invalid moe_offload '{moe_offload}'",
                "allowed": list(ALLOWED_MOE_OFFLOAD) + ["<integer>"],
            })
            response.status_code = 400
            return add_cors_headers(response)

    if kv_cache not in ALLOWED_KV_CACHE:
        response = jsonify({"error": f"Invalid kv_cache '{kv_cache}'", "allowed": sorted(ALLOWED_KV_CACHE)})
        response.status_code = 400
        return add_cors_headers(response)

    response = Response(
        run_switch_and_stream(model, thinking, restart, moe_offload, kv_cache),
        mimetype="text/event-stream",
    )
    response.headers["X-Accel-Buffering"] = "no"
    return add_cors_headers(response)


if __name__ == "__main__":
    print(f"Model switcher listening on http://0.0.0.0:{CONTROL_PORT}")
    print(f"Working directory: {SCRIPT_DIR}")
    app.run(host="0.0.0.0", port=CONTROL_PORT, debug=False, threaded=True)
