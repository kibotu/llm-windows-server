#!/usr/bin/env python3
"""
Usage tracking proxy for llama.cpp server.
Tracks token usage per request with per-day, per-session, and per-client aggregation.
"""

import json
import os
import threading
from datetime import datetime, timedelta
from typing import Dict, Any, List, Optional
import requests
from flask import Flask, request, Response, jsonify

app = Flask(__name__)

LLAMA_SERVER_URL = os.environ.get("LLAMA_SERVER_URL", "http://llm:8888")
TRACKING_FILE = "/data/usage_data.json"
SESSION_GAP_MINUTES = 30

# Thread-safe data storage
data_lock = threading.Lock()
usage_data: Dict[str, List[Dict[str, Any]]] = {"requests": []}


def load_usage_data():
    """Load usage data from disk."""
    global usage_data
    try:
        with open(TRACKING_FILE, "r") as f:
            data = json.load(f)
            with data_lock:
                usage_data = data if isinstance(data, dict) and "requests" in data else {"requests": []}
        print(f"Loaded {len(usage_data['requests'])} requests from {TRACKING_FILE}")
    except FileNotFoundError:
        print(f"No existing usage data found at {TRACKING_FILE}, starting fresh")
        with data_lock:
            usage_data = {"requests": []}
    except Exception as e:
        print(f"Error loading usage data: {e}, starting fresh")
        with data_lock:
            usage_data = {"requests": []}


def save_usage_data():
    """Save usage data to disk."""
    try:
        with data_lock:
            data_copy = {"requests": usage_data["requests"][:]}
        with open(TRACKING_FILE, "w") as f:
            json.dump(data_copy, f, indent=2)
        print(f"Saved {len(data_copy['requests'])} requests to {TRACKING_FILE}")
    except Exception as e:
        print(f"Error saving usage data: {e}")


def extract_client_info(req) -> tuple[str, str, str]:
    """Extract IP, user agent, and client_id from request."""
    # Determine IP address
    if req.headers.get("X-Forwarded-For"):
        ip_address = req.headers.get("X-Forwarded-For").split(",")[0].strip()
        # If X-Forwarded-For is a private IP, use remote_addr instead
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
        "streaming": streaming
    }
    
    with data_lock:
        usage_data["requests"].append(record)
    
    save_usage_data()
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


@app.route("/", defaults={"path": ""})
@app.route("/<path:path>", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
def proxy(path):
    """Proxy all requests to llama.cpp server and track usage."""
    if request.method == "OPTIONS":
        response = Response("")
        return add_cors_headers(response)
    
    # Block /usage paths from being proxied
    if path.startswith("usage"):
        return Response("Not Found", status=404)
    
    print(f"[PROXY] {request.method} /{path} from {request.remote_addr}")
    
    ip, user_agent, client_id = extract_client_info(request)
    
    url = f"{LLAMA_SERVER_URL}/{path}"
    headers = {key: value for (key, value) in request.headers if key.lower() != "host"}
    
    try:
        # Forward request to llama.cpp
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
        
        # Handle streaming (SSE) responses
        if resp.headers.get("Content-Type", "").startswith("text/event-stream"):
            def generate():
                buffer = ""
                last_data = None
                
                for chunk in resp.iter_content(chunk_size=4096):
                    if chunk:
                        # Immediately yield to client
                        yield chunk
                        
                        # Buffer for parsing
                        buffer += chunk.decode("utf-8", errors="replace")
                        
                        # Parse complete lines
                        while "\n" in buffer:
                            line, buffer = buffer.split("\n", 1)
                            line = line.strip()
                            
                            if line.startswith("data: ") and line != "data: [DONE]":
                                try:
                                    last_data = json.loads(line[6:])
                                except json.JSONDecodeError:
                                    pass
                
                # Record usage from the last data chunk
                if last_data:
                    record_usage(client_id, ip, user_agent, path, last_data, streaming=True)
            
            response = Response(generate(), status=resp.status_code, headers=dict(resp.headers))
            return add_cors_headers(response)
        
        # Handle non-streaming responses
        else:
            content = resp.content
            try:
                response_json = json.loads(content.decode("utf-8"))
                record_usage(client_id, ip, user_agent, path, response_json, streaming=False)
            except Exception as e:
                print(f"[TRACK] Error parsing response: {e}")
            
            response = Response(content, status=resp.status_code, headers=dict(resp.headers))
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
            # Start new session
            if current_session:
                sessions.append({
                    "client_id": current_session["client_id"],
                    "start": current_session["start"].isoformat(),
                    "end": current_session["last_ts"].isoformat(),
                    "prompt_tokens": current_session["prompt_tokens"],
                    "completion_tokens": current_session["completion_tokens"],
                    "total_tokens": current_session["total_tokens"],
                    "request_count": current_session["request_count"]
                })
            
            current_session = {
                "client_id": client_id,
                "start": ts,
                "last_ts": ts,
                "prompt_tokens": req["prompt_tokens"],
                "completion_tokens": req["completion_tokens"],
                "total_tokens": req["total_tokens"],
                "request_count": 1
            }
        else:
            # Continue current session
            current_session["last_ts"] = ts
            current_session["prompt_tokens"] += req["prompt_tokens"]
            current_session["completion_tokens"] += req["completion_tokens"]
            current_session["total_tokens"] += req["total_tokens"]
            current_session["request_count"] += 1
    
    # Add final session
    if current_session:
        sessions.append({
            "client_id": current_session["client_id"],
            "start": current_session["start"].isoformat(),
            "end": current_session["last_ts"].isoformat(),
            "prompt_tokens": current_session["prompt_tokens"],
            "completion_tokens": current_session["completion_tokens"],
            "total_tokens": current_session["total_tokens"],
            "request_count": current_session["request_count"]
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
    
    # Filter today's requests
    today_requests = [
        r for r in requests_copy 
        if datetime.fromisoformat(r["ts"]).date().isoformat() == today
    ]
    
    # Sort by timestamp for session detection
    today_requests.sort(key=lambda r: r["ts"])
    
    # Aggregate by client
    by_client = {}
    total_prompt = 0
    total_completion = 0
    total_tokens = 0
    total_requests = 0
    
    for req in today_requests:
        client_id = req["client_id"]
        
        if client_id not in by_client:
            by_client[client_id] = {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
                "request_count": 0
            }
        
        by_client[client_id]["prompt_tokens"] += req["prompt_tokens"]
        by_client[client_id]["completion_tokens"] += req["completion_tokens"]
        by_client[client_id]["total_tokens"] += req["total_tokens"]
        by_client[client_id]["request_count"] += 1
        
        total_prompt += req["prompt_tokens"]
        total_completion += req["completion_tokens"]
        total_tokens += req["total_tokens"]
        total_requests += 1
    
    # Detect sessions
    sessions = detect_sessions(today_requests)
    
    result = {
        "date": today,
        "total": {
            "prompt_tokens": total_prompt,
            "completion_tokens": total_completion,
            "total_tokens": total_tokens,
            "request_count": total_requests
        },
        "by_client": by_client,
        "sessions": sessions
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
        requests_copy = usage_data["requests"][:]
    
    # Aggregate by day
    days = {}
    totals_by_client = {}
    
    for req in requests_copy:
        day = datetime.fromisoformat(req["ts"]).date().isoformat()
        client_id = req["client_id"]
        
        # Per-day aggregation
        if day not in days:
            days[day] = {
                "total": {
                    "prompt_tokens": 0,
                    "completion_tokens": 0,
                    "total_tokens": 0,
                    "request_count": 0
                },
                "by_client": {}
            }
        
        if client_id not in days[day]["by_client"]:
            days[day]["by_client"][client_id] = {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
                "request_count": 0
            }
        
        days[day]["by_client"][client_id]["prompt_tokens"] += req["prompt_tokens"]
        days[day]["by_client"][client_id]["completion_tokens"] += req["completion_tokens"]
        days[day]["by_client"][client_id]["total_tokens"] += req["total_tokens"]
        days[day]["by_client"][client_id]["request_count"] += 1
        
        days[day]["total"]["prompt_tokens"] += req["prompt_tokens"]
        days[day]["total"]["completion_tokens"] += req["completion_tokens"]
        days[day]["total"]["total_tokens"] += req["total_tokens"]
        days[day]["total"]["request_count"] += 1
        
        # All-time per-client totals
        if client_id not in totals_by_client:
            totals_by_client[client_id] = {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
                "request_count": 0
            }
        
        totals_by_client[client_id]["prompt_tokens"] += req["prompt_tokens"]
        totals_by_client[client_id]["completion_tokens"] += req["completion_tokens"]
        totals_by_client[client_id]["total_tokens"] += req["total_tokens"]
        totals_by_client[client_id]["request_count"] += 1
    
    result = {
        "days": days,
        "totals_by_client": totals_by_client
    }
    
    response = jsonify(result)
    return add_cors_headers(response)


if __name__ == "__main__":
    load_usage_data()
    print(f"Starting usage tracking proxy on http://0.0.0.0:8899")
    print(f"Forwarding to llama.cpp server at {LLAMA_SERVER_URL}")
    print(f"Session gap: {SESSION_GAP_MINUTES} minutes")
    
    app.run(host="0.0.0.0", port=8899, debug=False, threaded=True)
