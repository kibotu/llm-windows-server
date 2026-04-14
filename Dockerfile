# Usage-tracker image only. The LLM runs from ghcr.io/ggml-org/llama.cpp:server-cuda with
# command-line flags and env vars documented in docker-compose.yml (llm service) and README.md.
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip install --no-cache-dir flask requests

COPY usage_tracker.py .

EXPOSE 8899

CMD ["python", "usage_tracker.py"]