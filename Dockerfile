FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip install --no-cache-dir flask requests

COPY usage_tracker.py .

EXPOSE 8899

CMD ["python", "usage_tracker.py"]