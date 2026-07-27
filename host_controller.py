#!/usr/bin/env python3
"""
Host-side controller for the llm-server stack.

Runs on the Windows host (not inside Docker). The gateway proxy forwards
/mcp requests to mcp/server.py, which calls this controller for admin operations.

Start once and leave running:
    python host_controller.py

run.ps1 also auto-starts this if it is not already listening.
"""

from __future__ import annotations

import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
RUN_PS1 = SCRIPT_DIR / "run.ps1"
RUNTIME_STATE_FILE = SCRIPT_DIR / "usage_data" / "runtime_state.json"
VALID_MODELS = frozenset({"qwen36", "heretic", "qwen35-9b"})
BIND_HOST = os.environ.get("HOST_CONTROLLER_BIND", "127.0.0.1")
BIND_PORT = int(os.environ.get("HOST_CONTROLLER_PORT", "8900"))


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _read_dotenv(key: str) -> str:
    env_file = SCRIPT_DIR / ".env"
    if not env_file.is_file():
        return ""
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.+?)\s*$")
    for line in env_file.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1).strip()
    return ""


ADMIN_KEY = (
    os.environ.get("LLAMA_ADMIN_KEY", "").strip()
    or _read_dotenv("LLAMA_ADMIN_KEY")
    or os.environ.get("LLAMA_API_KEY", "").strip()
    or _read_dotenv("LLAMA_API_KEY")
)

MODEL_CATALOG: dict[str, dict[str, Any]] = {
    "qwen36": {
        "label": "Qwen3.6-35B-A3B IQ4_XS (vision, MoE)",
        "model_file": "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
        "default_context": 262144,
    },
    "heretic": {
        "label": "Qwen3.6-35B-A3B Heretic Cerebellum 14GB (vision, MoE)",
        "model_file": "Qwen3.6-35B-A3B-Heretic-Cerebellum-14GB.gguf",
        "default_context": 262144,
    },
    "qwen35-9b": {
        "label": "Qwen3.5-9B Q4_K_M (vision, dense)",
        "model_file": "Qwen3.5-9B-Q4_K_M.gguf",
        "default_context": 128000,
    },
}


def _write_runtime_state(state: dict[str, Any]) -> None:
    RUNTIME_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = RUNTIME_STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2), encoding="utf-8")
    tmp.replace(RUNTIME_STATE_FILE)


def _read_runtime_state() -> dict[str, Any]:
    if not RUNTIME_STATE_FILE.is_file():
        return {"status": "unknown"}
    try:
        return json.loads(RUNTIME_STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {"status": "unknown"}


class ReconcileManager:
    """Single-flight reconcile jobs. A new request cancels the in-flight run.ps1."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._proc: subprocess.Popen[str] | None = None
        self._job: dict[str, Any] = {"status": "idle"}

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            job = dict(self._job)
            if self._proc and self._proc.poll() is None:
                job["pid"] = self._proc.pid
            return job

    def _subprocess_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUTF8"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env.pop("HF_HUB_ENABLE_HF_TRANSFER", None)
        for key in ("HF_TOKEN", "LLAMA_API_KEY", "LLAMA_ADMIN_KEY"):
            value = _read_dotenv(key)
            if value:
                env[key] = value
        return env

    def start(self, params: dict[str, Any], *, cancel: bool = True) -> dict[str, Any]:
        with self._lock:
            if self._proc and self._proc.poll() is None:
                if not cancel:
                    return {
                        "status": "busy",
                        "message": "A reconcile is already running. Retry with cancel=true.",
                        "job": dict(self._job),
                    }
                self._terminate(self._proc)

            model = params.get("model", "qwen36")
            if model not in VALID_MODELS:
                return {
                    "status": "error",
                    "message": f"Invalid model '{model}'. Valid: {sorted(VALID_MODELS)}",
                }

            cmd = self._build_command(params)
            self._job = {
                "status": "running",
                "model": model,
                "params": params,
                "started_at": _utc_now(),
                "command": cmd,
            }
            _write_runtime_state(
                {
                    "status": "running",
                    "model": model,
                    "label": MODEL_CATALOG[model]["label"],
                    "model_file": MODEL_CATALOG[model]["model_file"],
                    "context": params.get("context", MODEL_CATALOG[model]["default_context"]),
                    "started_at": self._job["started_at"],
                }
            )

            self._proc = subprocess.Popen(
                cmd,
                cwd=str(SCRIPT_DIR),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=self._subprocess_env(),
            )
            threading.Thread(target=self._wait, daemon=True).start()
            return {"status": "accepted", "job": dict(self._job)}

    def _build_command(self, params: dict[str, Any]) -> list[str]:
        model = params.get("model", "qwen36")
        args = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(RUN_PS1),
            "-NoFollow",
            "-Model",
            model,
        ]

        if "context" in params:
            args.extend(["-Context", str(int(params["context"]))])
        if "parallel" in params:
            args.extend(["-Parallel", str(int(params["parallel"]))])
        if "threads" in params:
            args.extend(["-Threads", str(int(params["threads"]))])
        if "batch" in params:
            args.extend(["-Batch", str(int(params["batch"]))])
        if "ubatch" in params:
            args.extend(["-UBatch", str(int(params["ubatch"]))])
        if "kvcache" in params:
            args.extend(["-KvCache", str(params["kvcache"])])
        if "moe_offload" in params:
            args.extend(["-MoeOffload", str(params["moe_offload"])])
        if "extra_flags" in params and params["extra_flags"]:
            args.extend(["-ExtraFlags", str(params["extra_flags"])])
        if params.get("no_download"):
            args.append("-NoDownload")

        if "thinking" in params:
            args.append("-Thinking" if params["thinking"] else "-Thinking:$false")
        if "vision" in params:
            args.append("-Vision" if params["vision"] else "-Vision:$false")

        return args

    def _terminate(self, proc: subprocess.Popen[str]) -> None:
        if proc.poll() is not None:
            return
        try:
            subprocess.run(
                ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
        except Exception:
            proc.kill()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

    def _wait(self) -> None:
        proc = self._proc
        if proc is None:
            return

        output = ""
        try:
            output, _ = proc.communicate(timeout=600)
        except subprocess.TimeoutExpired:
            self._terminate(proc)
            output = (output or "") + "\n[host_controller] timed out after 600s"
            exit_code = -1
        else:
            exit_code = proc.returncode

        with self._lock:
            finished_at = _utc_now()
            if exit_code == 0:
                self._job = {
                    "status": "ready",
                    "finished_at": finished_at,
                    "exit_code": exit_code,
                    "model": self._job.get("model"),
                    "params": self._job.get("params"),
                }
            else:
                tail = "\n".join((output or "").splitlines()[-40:])
                self._job = {
                    "status": "failed",
                    "finished_at": finished_at,
                    "exit_code": exit_code,
                    "model": self._job.get("model"),
                    "params": self._job.get("params"),
                    "error": tail or f"run.ps1 exited with code {exit_code}",
                }
                prev = _read_runtime_state()
                _write_runtime_state(
                    {
                        **prev,
                        "status": "failed",
                        "model": self._job.get("model") or prev.get("model"),
                        "finished_at": finished_at,
                        "error": self._job["error"],
                    }
                )
            self._proc = None


reconcile_manager = ReconcileManager()


def _authorized(headers: dict[str, str]) -> bool:
    if not ADMIN_KEY:
        return True
    provided = ""
    auth = headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        provided = auth[len("Bearer ") :].strip()
    if not provided:
        provided = headers.get("X-Api-Key") or headers.get("Api-Key") or ""
    return bool(provided) and hmac.compare_digest(provided, ADMIN_KEY)


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, Any]) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class ControllerHandler(BaseHTTPRequestHandler):
    server_version = "llm-host-controller/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[host_controller] {self.address_string()} - {fmt % args}")

    def _headers_dict(self) -> dict[str, str]:
        return {k: v for k, v in self.headers.items()}

    def _read_json_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not raw:
            return {}
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, dict) else {}

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Api-Key")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/health":
            return _json_response(self, 200, {"status": "ok"})

        if path in ("/admin/status", "/admin/models"):
            if not _authorized(self._headers_dict()):
                return _json_response(
                    self,
                    401,
                    {"error": {"message": "Invalid or missing admin API key", "code": "invalid_api_key"}},
                )
            if path == "/admin/models":
                return _json_response(
                    self,
                    200,
                    {
                        "models": [
                            {"id": model_id, **meta}
                            for model_id, meta in MODEL_CATALOG.items()
                        ]
                    },
                )
            return _json_response(
                self,
                200,
                {
                    "runtime": _read_runtime_state(),
                    "job": reconcile_manager.snapshot(),
                },
            )

        return _json_response(self, 404, {"error": {"message": "Not found"}})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"

        if path not in ("/admin/reconcile", "/admin/start", "/admin/stop"):
            return _json_response(self, 404, {"error": {"message": "Not found"}})

        if not _authorized(self._headers_dict()):
            return _json_response(
                self,
                401,
                {"error": {"message": "Invalid or missing admin API key", "code": "invalid_api_key"}},
            )

        if path == "/admin/stop":
            return self._handle_stop()

        if path == "/admin/start":
            return self._handle_start()

        # /admin/reconcile
        try:
            body = self._read_json_body()
        except json.JSONDecodeError:
            return _json_response(self, 400, {"error": {"message": "Invalid JSON body"}})

        params = {k: v for k, v in body.items() if k != "cancel"}
        cancel = body.get("cancel", True)
        result = reconcile_manager.start(params, cancel=cancel)
        status = 202 if result.get("status") == "accepted" else 409 if result.get("status") == "busy" else 400
        return _json_response(self, status, result)

    def _handle_stop(self) -> None:
        """Stop the llm-server stack (docker compose down)."""
        cmd = [
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", str(RUN_PS1), "-Stop",
        ]
        try:
            result = subprocess.run(
                cmd, cwd=str(SCRIPT_DIR), capture_output=True, text=True,
                encoding="utf-8", errors="replace", timeout=60,
            )
            if result.returncode == 0:
                _write_runtime_state({"status": "stopped", "stopped_at": _utc_now()})
                return _json_response(self, 200, {
                    "status": "stopped",
                    "message": "Server stopped successfully",
                })
            else:
                tail = "\n".join(result.stdout.splitlines()[-20:])
                return _json_response(self, 500, {
                    "status": "error",
                    "message": f"Stop failed (exit {result.returncode})",
                    "output": tail,
                })
        except subprocess.TimeoutExpired:
            return _json_response(self, 504, {
                "status": "error",
                "message": "Stop command timed out after 60s",
            })
        except Exception as exc:
            return _json_response(self, 500, {
                "status": "error",
                "message": f"Failed to run stop command: {exc}",
            })

    def _handle_start(self) -> None:
        """Start the llm-server stack via reconcile (docker compose up)."""
        try:
            body = self._read_json_body()
        except json.JSONDecodeError:
            body = {}

        if not body.get("model"):
            runtime = _read_runtime_state()
            body.setdefault("model", runtime.get("model") or "qwen36")

        params = {k: v for k, v in body.items() if k != "cancel"}
        cancel = body.get("cancel", True)
        result = reconcile_manager.start(params, cancel=cancel)
        status = 202 if result.get("status") == "accepted" else 409 if result.get("status") == "busy" else 400
        return _json_response(self, status, result)


def main() -> None:
    if not RUN_PS1.is_file():
        print(f"run.ps1 not found at {RUN_PS1}", file=sys.stderr)
        sys.exit(1)

    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), ControllerHandler)
    auth_mode = "ENABLED" if ADMIN_KEY else "disabled (open)"
    print(f"Host controller listening on http://{BIND_HOST}:{BIND_PORT}")
    print(f"Admin auth: {auth_mode}")
    print(f"Script dir: {SCRIPT_DIR}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down host controller")
        server.server_close()


if __name__ == "__main__":
    main()
