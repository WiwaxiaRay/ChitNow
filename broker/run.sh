#!/bin/bash
set -e
cd "$(dirname "$0")"
.venv/bin/python generate_config.py
exec .venv/bin/uvicorn main:app \
    --host 0.0.0.0 \
    --port 8000 \
    --ssl-keyfile certs/broker.key \
    --ssl-certfile certs/broker.crt
