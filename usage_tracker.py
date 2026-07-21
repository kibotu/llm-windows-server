#!/usr/bin/env python3
"""
Usage tracking proxy for llama.cpp server.
Tracks token usage per request with per-day, per-session, and per-client aggregation.
"""

import hmac
import json
import logging
import os
import threading
from datetime import datetime, timedelta
from typing import Dict, Any, List
import requests
from flask import Flask, request, Response, jsonify

app = Flask(__name__)

LLAMA_SERVER_URL = os.environ.get("LLAMA_SERVER_URL", "http://llm:8888")
# Bearer key clients must present. Empty string disables auth (open server).
API_KEY = os.environ.get("LLAMA_API_KEY", "").strip()
# Admin key for /admin/* (model switching). Falls back to LLAMA_API_KEY.
ADMIN_KEY = os.environ.get("LLAMA_ADMIN_KEY", "").strip() or API_KEY
HOST_CONTROLLER_URL = os.environ.get("HOST_CONTROLLER_URL", "http://host.docker.internal:8900").rstrip("/")
TRACKING_DIR = "/data"
REQUESTS_LOG = os.path.join(TRACKING_DIR, "requests.jsonl")
SUMMARY_FILE = os.path.join(TRACKING_DIR, "daily_summary.json")
LEGACY_FILE = os.path.join(TRACKING_DIR, "usage_data.json")
RUNTIME_STATE_FILE = os.path.join(TRACKING_DIR, "runtime_state.json")
SESSION_GAP_MINUTES = 30

# Thread-safe data storage
data_lock = threading.Lock()
usage_data: Dict[str, List[Dict[str, Any]]] = {"requests": []}
daily_summary: Dict[str, Any] = {"days": {}, "totals_by_client": {}}


def is_authorized(req) -> bool:
    """True when auth is disabled, or the request carries the correct API key."""
    if not API_KEY:
        return True
    provided = ""
    auth = req.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        provided = auth[len("Bearer "):].strip()
    if not provided:
        provided = (req.headers.get("x-api-key") or req.headers.get("api-key") or "").strip()
    return bool(provided) and hmac.compare_digest(provided, API_KEY)


def is_admin_authorized(req) -> bool:
    """True when admin auth is disabled, or the request carries the admin key."""
    if not ADMIN_KEY:
        return True
    provided = ""
    auth = req.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        provided = auth[len("Bearer "):].strip()
    if not provided:
        provided = (req.headers.get("x-api-key") or req.headers.get("api-key") or "").strip()
    return bool(provided) and hmac.compare_digest(provided, ADMIN_KEY)


def _empty_summary() -> Dict[str, Any]:
    return {"days": {}, "totals_by_client": {}}


def _token_totals() -> Dict[str, int]:
    return {
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "total_tokens": 0,
        "request_count": 0,
    }


def _ensure_tracking_storage() -> None:
    """Ensure the tracking directory exists and storage files are usable."""
    os.makedirs(TRACKING_DIR, exist_ok=True)
    for path in (REQUESTS_LOG, SUMMARY_FILE, LEGACY_FILE):
        if os.path.isdir(path):
            raise RuntimeError(
                f"{path} is a directory, not a file. "
                "Remove it and mount ./usage_data as a directory (see docker-compose.yml)."
            )
    if not os.path.exists(REQUESTS_LOG):
        open(REQUESTS_LOG, "a", encoding="utf-8").close()
        print(f"Created empty request log at {REQUESTS_LOG}")
    if not os.path.exists(SUMMARY_FILE):
        _save_summary(_empty_summary())
        print(f"Created empty summary at {SUMMARY_FILE}")


def _load_summary() -> Dict[str, Any]:
    try:
        with open(SUMMARY_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and "days" in data and "totals_by_client" in data:
            return data
    except FileNotFoundError:
        pass
    except Exception as e:
        print(f"Error loading summary file: {e}")
    return _empty_summary()


def _save_summary(summary: Dict[str, Any]) -> None:
    tmp_path = f"{SUMMARY_FILE}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    os.replace(tmp_path, SUMMARY_FILE)


def _append_request_line(record: Dict[str, Any]) -> None:
    line = json.dumps(record, separators=(",", ":"))
    with open(REQUESTS_LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def _load_requests_from_log() -> List[Dict[str, Any]]:
    requests_list: List[Dict[str, Any]] = []
    if not os.path.exists(REQUESTS_LOG):
        return requests_list

    with open(REQUESTS_LOG, "r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"Skipping malformed log line {line_no}: {e}")
                continue
            if isinstance(record, dict):
                requests_list.append(record)
    return requests_list


def _migrate_legacy_file() -> None:
    if not os.path.exists(LEGACY_FILE):
        return

    try:
        with open(LEGACY_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"Could not migrate legacy usage file: {e}")
        return

    legacy_requests = data.get("requests", []) if isinstance(data, dict) else []
    if not legacy_requests:
        return

    existing = _load_requests_from_log()
    if existing:
        print("Legacy usage file present but request log already has data; skipping migration")
        return

    for record in legacy_requests:
        if isinstance(record, dict):
            _append_request_line(record)
    migrated_path = f"{LEGACY_FILE}.migrated"
    os.replace(LEGACY_FILE, migrated_path)
    print(f"Migrated {len(legacy_requests)} requests from legacy usage_data.json to requests.jsonl")


def _update_summary(record: Dict[str, Any]) -> None:
    day = datetime.fromisoformat(record["ts"]).date().isoformat()
    client_id = record["client_id"]

    if day not in daily_summary["days"]:
        daily_summary["days"][day] = {"total": _token_totals(), "by_client": {}}

    day_entry = daily_summary["days"][day]
    if client_id not in day_entry["by_client"]:
        day_entry["by_client"][client_id] = _token_totals()
    if client_id not in daily_summary["totals_by_client"]:
        daily_summary["totals_by_client"][client_id] = _token_totals()

    for bucket in (
        day_entry["total"],
        day_entry["by_client"][client_id],
        daily_summary["totals_by_client"][client_id],
    ):
        bucket["prompt_tokens"] += record["prompt_tokens"]
        bucket["completion_tokens"] += record["completion_tokens"]
        bucket["total_tokens"] += record["total_tokens"]
        bucket["request_count"] += 1


def _rebuild_summary_from_requests(requests_list: List[Dict[str, Any]]) -> Dict[str, Any]:
    summary = _empty_summary()
    for record in requests_list:
        day = datetime.fromisoformat(record["ts"]).date().isoformat()
        client_id = record["client_id"]

        if day not in summary["days"]:
            summary["days"][day] = {"total": _token_totals(), "by_client": {}}
        day_entry = summary["days"][day]
        if client_id not in day_entry["by_client"]:
            day_entry["by_client"][client_id] = _token_totals()
        if client_id not in summary["totals_by_client"]:
            summary["totals_by_client"][client_id] = _token_totals()

        for bucket in (
            day_entry["total"],
            day_entry["by_client"][client_id],
            summary["totals_by_client"][client_id],
        ):
            bucket["prompt_tokens"] += record["prompt_tokens"]
            bucket["completion_tokens"] += record["completion_tokens"]
            bucket["total_tokens"] += record["total_tokens"]
            bucket["request_count"] += 1
    return summary


def load_usage_data():
    """Load persisted usage history and aggregated summaries."""
    global usage_data, daily_summary
    _ensure_tracking_storage()
    _migrate_legacy_file()

    requests_list = _load_requests_from_log()
    summary = _load_summary()

    if requests_list and not summary["days"] and not summary["totals_by_client"]:
        print("Summary file empty; rebuilding aggregates from request log")
        summary = _rebuild_summary_from_requests(requests_list)
        _save_summary(summary)

    with data_lock:
        usage_data = {"requests": requests_list}
        daily_summary = summary

    print(
        f"Loaded {len(requests_list)} requests from {REQUESTS_LOG} "
        f"and {len(summary['days'])} day(s) of aggregates from {SUMMARY_FILE}"
    )


def persist_usage_record(record: Dict[str, Any]) -> None:
    """Append one request and update persisted aggregates."""
    _append_request_line(record)
    _update_summary(record)
    _save_summary(daily_summary)


def extract_client_info(req) -> tuple[str, str, str]:
    """Extract IP, user agent, and client_id from request."""
    if req.headers.get("X-Forwarded-For"):
        ip_address = req.headers.get("X-Forwarded-For").split(",")[0].strip()
        if ip_address.startswith((
            "10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.20.",
            "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.",
            "172.27.", "172.28.", "172.29.", "172.30.", "172.31.", "192.168.", "127."
        )):
            ip_address = req.remote_addr or ip_address
    else:
        ip_address = req.remote_addr or "unknown"

    user_agent = req.headers.get("User-Agent", "unknown")[:80]
    client_id = f"{ip_address}_{user_agent}" if user_agent != "unknown" else ip_address

    return ip_address, user_agent, client_id


def record_usage(client_id: str, ip: str, user_agent: str, path: str,
                 response_data: Dict[str, Any], streaming: bool):
    """Record a single request's usage."""
    if "usage" not in response_data:
        print(f"[TRACK] No usage data in response for {path}")
        return

    usage = response_data["usage"]
    prompt_tokens = usage.get("prompt_tokens", 0)
    completion_tokens = usage.get("completion_tokens", 0)
    total_tokens = usage.get("total_tokens", 0)

    if prompt_tokens == 0 and completion_tokens == 0:
        print(f"[TRACK] Zero tokens in response for {path}")
        return

    model = response_data.get("model", "unknown")

    record = {
        "ts": datetime.utcnow().isoformat(),
        "client_id": client_id,
        "ip": ip,
        "user_agent": user_agent,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": total_tokens,
        "model": model,
        "path": path,
        "streaming": streaming,
    }

    with data_lock:
        usage_data["requests"].append(record)
        persist_usage_record(record)

    print(f"[TRACK] Recorded {total_tokens} tokens for {client_id} ({path}, streaming={streaming})")


def add_cors_headers(response):
    """Add CORS headers to response."""
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, PATCH, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response


# Hop-by-hop headers from upstream must not be forwarded — Flask/Werkzeug sets
# Transfer-Encoding itself for streamed bodies; copying upstream values causes
# "Transfer-Encoding: chunked, chunked" and breaks strict clients (httpx/OpenAI SDK).
_HOP_BY_HOP = frozenset({
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
})


def filter_proxy_headers(upstream_headers) -> Dict[str, str]:
    """Return upstream headers safe to pass through the Flask proxy."""
    return {
        key: value
        for key, value in upstream_headers.items()
        if key.lower() not in _HOP_BY_HOP and key.lower() != "content-length"
    }


def _read_runtime_state() -> Dict[str, Any]:
    if not os.path.exists(RUNTIME_STATE_FILE):
        return {"status": "unknown"}
    try:
        with open(RUNTIME_STATE_FILE, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {"status": "unknown"}
    except Exception:
        return {"status": "unknown"}


def _llm_health() -> Dict[str, Any]:
    try:
        resp = requests.get(f"{LLAMA_SERVER_URL}/health", timeout=5)
        return {"healthy": resp.status_code == 200, "status_code": resp.status_code}
    except requests.exceptions.RequestException as exc:
        return {"healthy": False, "error": str(exc)}


def _admin_auth_headers(req) -> Dict[str, str]:
    headers = {}
    auth = req.headers.get("Authorization")
    if auth:
        headers["Authorization"] = auth
    for key in ("X-Api-Key", "Api-Key"):
        value = req.headers.get(key)
        if value:
            headers[key] = value
    return headers


def _forward_admin(method: str, path: str, req) -> Response:
    url = f"{HOST_CONTROLLER_URL}/{path.lstrip('/')}"
    headers = _admin_auth_headers(req)
    try:
        if method == "GET":
            upstream = requests.get(url, headers=headers, params=request.args, timeout=30)
        else:
            upstream = requests.post(
                url,
                headers={**headers, "Content-Type": "application/json"},
                data=request.get_data(),
                timeout=30,
            )
    except requests.exceptions.RequestException as exc:
        body = json.dumps({
            "error": {
                "message": (
                    f"Host controller unreachable at {HOST_CONTROLLER_URL}. "
                    "Start it on the Windows host: python host_controller.py"
                ),
                "detail": str(exc),
                "code": "host_controller_unavailable",
            }
        })
        resp = Response(body, status=503, mimetype="application/json")
        return add_cors_headers(resp)

    resp = Response(upstream.content, status=upstream.status_code, mimetype="application/json")
    return add_cors_headers(resp)


@app.route("/admin/status", methods=["GET", "OPTIONS"])
@app.route("/admin/status/", methods=["GET", "OPTIONS"])
def admin_status():
    """Current runtime model state + llama.cpp health + host-controller job status."""
    if request.method == "OPTIONS":
        return add_cors_headers(Response(""))

    if not is_admin_authorized(request):
        body = json.dumps({"error": {
            "message": "Invalid or missing admin API key",
            "type": "invalid_request_error",
            "code": "invalid_api_key",
        }})
        resp = Response(body, status=401, mimetype="application/json")
        resp.headers["WWW-Authenticate"] = "Bearer"
        return add_cors_headers(resp)

    payload = {
        "runtime": _read_runtime_state(),
        "llm": _llm_health(),
    }

    try:
        upstream = requests.get(
            f"{HOST_CONTROLLER_URL}/admin/status",
            headers=_admin_auth_headers(request),
            timeout=10,
        )
        if upstream.ok:
            payload["job"] = upstream.json().get("job")
    except requests.exceptions.RequestException:
        payload["job"] = {"status": "host_controller_unavailable"}

    return add_cors_headers(jsonify(payload))


@app.route("/admin/models", methods=["GET", "OPTIONS"])
@app.route("/admin/models/", methods=["GET", "OPTIONS"])
def admin_models():
    """List switchable model aliases (qwen36, qwen35-9b)."""
    if request.method == "OPTIONS":
        return add_cors_headers(Response(""))

    if not is_admin_authorized(request):
        body = json.dumps({"error": {
            "message": "Invalid or missing admin API key",
            "type": "invalid_request_error",
            "code": "invalid_api_key",
        }})
        resp = Response(body, status=401, mimetype="application/json")
        resp.headers["WWW-Authenticate"] = "Bearer"
        return add_cors_headers(resp)

    return _forward_admin("GET", "admin/models", request)


@app.route("/admin/reconcile", methods=["POST", "OPTIONS"])
@app.route("/admin/reconcile/", methods=["POST", "OPTIONS"])
def admin_reconcile():
    """Switch the loaded model by re-running run.ps1 on the Windows host."""
    if request.method == "OPTIONS":
        return add_cors_headers(Response(""))

    if not is_admin_authorized(request):
        body = json.dumps({"error": {
            "message": "Invalid or missing admin API key",
            "type": "invalid_request_error",
            "code": "invalid_api_key",
        }})
        resp = Response(body, status=401, mimetype="application/json")
        resp.headers["WWW-Authenticate"] = "Bearer"
        return add_cors_headers(resp)

    return _forward_admin("POST", "admin/reconcile", request)


@app.route("/", defaults={"path": ""})
@app.route("/<path:path>", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
def proxy(path):
    """Proxy all requests to llama.cpp server and track usage."""
    if request.method == "OPTIONS":
        response = Response("")
        return add_cors_headers(response)

    if path != "health" and not is_authorized(request):
        body = json.dumps({"error": {
            "message": "Invalid or missing API key",
            "type": "invalid_request_error",
            "code": "invalid_api_key",
        }})
        resp = Response(body, status=401, mimetype="application/json")
        resp.headers["WWW-Authenticate"] = "Bearer"
        return add_cors_headers(resp)

    if path.startswith("usage"):
        return Response("Not Found", status=404)

    if path.startswith("admin"):
        return Response("Not Found", status=404)

    print(f"[PROXY] {request.method} /{path} from {request.remote_addr}")

    ip, user_agent, client_id = extract_client_info(request)

    url = f"{LLAMA_SERVER_URL}/{path}"
    headers = {key: value for (key, value) in request.headers if key.lower() != "host"}

    try:
        if request.method == "GET":
            resp = requests.get(url, headers=headers, params=request.args, stream=True)
        elif request.method in ["POST", "PUT", "PATCH"]:
            method_func = getattr(requests, request.method.lower())
            resp = method_func(url, headers=headers, data=request.get_data(),
                               params=request.args, stream=True)
        elif request.method == "DELETE":
            resp = requests.delete(url, headers=headers, data=request.get_data(),
                                   params=request.args, stream=True)
        else:
            return Response(f"Method {request.method} not allowed", status=405)

        if resp.headers.get("Content-Type", "").startswith("text/event-stream"):
            def generate():
                buffer = ""
                last_data = None

                for chunk in resp.iter_content(chunk_size=4096):
                    if chunk:
                        yield chunk
                        buffer += chunk.decode("utf-8", errors="replace")
                        while "\n" in buffer:
                            line, buffer = buffer.split("\n", 1)
                            line = line.strip()
                            if line.startswith("data: ") and line != "data: [DONE]":
                                try:
                                    last_data = json.loads(line[6:])
                                except json.JSONDecodeError:
                                    pass

                if last_data:
                    record_usage(client_id, ip, user_agent, path, last_data, streaming=True)

            response = Response(
                generate(), status=resp.status_code,
                headers=filter_proxy_headers(resp.headers),
            )
            return add_cors_headers(response)

        content = resp.content
        try:
            response_json = json.loads(content.decode("utf-8"))
            record_usage(client_id, ip, user_agent, path, response_json, streaming=False)
        except Exception as e:
            print(f"[TRACK] Error parsing response: {e}")

        response = Response(
            content, status=resp.status_code,
            headers=filter_proxy_headers(resp.headers),
        )
        return add_cors_headers(response)

    except requests.exceptions.RequestException as e:
        return Response(f"Error connecting to llama.cpp server: {str(e)}", status=502)
    except Exception as e:
        return Response(f"Internal proxy error: {str(e)}", status=500)


def detect_sessions(requests_list: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Detect sessions from a list of requests (must be sorted by timestamp)."""
    if not requests_list:
        return []

    sessions = []
    current_session = None
    session_gap = timedelta(minutes=SESSION_GAP_MINUTES)

    for req in requests_list:
        ts = datetime.fromisoformat(req["ts"])
        client_id = req["client_id"]

        if current_session is None or \
           client_id != current_session["client_id"] or \
           (ts - current_session["last_ts"]) > session_gap:
            if current_session:
                sessions.append({
                    "client_id": current_session["client_id"],
                    "start": current_session["start"].isoformat(),
                    "end": current_session["last_ts"].isoformat(),
                    "prompt_tokens": current_session["prompt_tokens"],
                    "completion_tokens": current_session["completion_tokens"],
                    "total_tokens": current_session["total_tokens"],
                    "request_count": current_session["request_count"],
                })

            current_session = {
                "client_id": client_id,
                "start": ts,
                "last_ts": ts,
                "prompt_tokens": req["prompt_tokens"],
                "completion_tokens": req["completion_tokens"],
                "total_tokens": req["total_tokens"],
                "request_count": 1,
            }
        else:
            current_session["last_ts"] = ts
            current_session["prompt_tokens"] += req["prompt_tokens"]
            current_session["completion_tokens"] += req["completion_tokens"]
            current_session["total_tokens"] += req["total_tokens"]
            current_session["request_count"] += 1

    if current_session:
        sessions.append({
            "client_id": current_session["client_id"],
            "start": current_session["start"].isoformat(),
            "end": current_session["last_ts"].isoformat(),
            "prompt_tokens": current_session["prompt_tokens"],
            "completion_tokens": current_session["completion_tokens"],
            "total_tokens": current_session["total_tokens"],
            "request_count": current_session["request_count"],
        })

    return sessions


@app.route("/usage", methods=["GET", "OPTIONS"])
@app.route("/usage/", methods=["GET", "OPTIONS"])
def get_usage():
    """Get today's usage summary with per-client breakdown and sessions."""
    if request.method == "OPTIONS":
        response = Response("")
        return add_cors_headers(response)

    today = datetime.utcnow().date().isoformat()

    with data_lock:
        requests_copy = usage_data["requests"][:]
        today_summary = daily_summary["days"].get(today)

    today_requests = [
        r for r in requests_copy
        if datetime.fromisoformat(r["ts"]).date().isoformat() == today
    ]
    today_requests.sort(key=lambda r: r["ts"])

    if today_summary:
        result = {
            "date": today,
            "total": today_summary["total"],
            "by_client": today_summary["by_client"],
            "sessions": detect_sessions(today_requests),
        }
    else:
        by_client = {}
        total = _token_totals()
        for req in today_requests:
            client_id = req["client_id"]
            if client_id not in by_client:
                by_client[client_id] = _token_totals()
            for bucket in (by_client[client_id], total):
                bucket["prompt_tokens"] += req["prompt_tokens"]
                bucket["completion_tokens"] += req["completion_tokens"]
                bucket["total_tokens"] += req["total_tokens"]
                bucket["request_count"] += 1
        result = {
            "date": today,
            "total": total,
            "by_client": by_client,
            "sessions": detect_sessions(today_requests),
        }

    response = jsonify(result)
    return add_cors_headers(response)


@app.route("/usage/history", methods=["GET", "OPTIONS"])
@app.route("/usage/history/", methods=["GET", "OPTIONS"])
def get_usage_history():
    """Get full usage history with per-day and per-client totals."""
    if request.method == "OPTIONS":
        response = Response("")
        return add_cors_headers(response)

    with data_lock:
        summary_copy = {
            "days": json.loads(json.dumps(daily_summary["days"])),
            "totals_by_client": json.loads(json.dumps(daily_summary["totals_by_client"])),
        }

    response = jsonify(summary_copy)
    return add_cors_headers(response)


if __name__ == "__main__":
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    load_usage_data()
    print(f"Starting usage tracking proxy on http://0.0.0.0:8899")
    print(f"Forwarding to llama.cpp server at {LLAMA_SERVER_URL}")
    print(f"Session gap: {SESSION_GAP_MINUTES} minutes")
    print(f"API key auth: {'ENABLED' if API_KEY else 'disabled (open server)'}")
    print(f"Admin API: /admin/status /admin/models /admin/reconcile")
    print(f"Host controller: {HOST_CONTROLLER_URL}")
    print(f"Admin auth: {'ENABLED' if ADMIN_KEY else 'disabled (open server)'}")

    app.run(host="0.0.0.0", port=8899, debug=False, threaded=True)
