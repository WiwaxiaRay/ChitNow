#!/bin/bash
set -e
cd "$(dirname "$0")"
.venv/bin/python generate_config.py

# Restrict permissions on sensitive files before starting the server.
# umask 077 ensures broker.db and broker.log are created as 600.
umask 077
chmod 600 config.json certs/broker.key 2>/dev/null || true
chmod 644 certs/broker.crt certs/fingerprint.txt 2>/dev/null || true

exec .venv/bin/uvicorn main:app \
    --host 0.0.0.0 \
    --port 8000 \
    --ssl-keyfile certs/broker.key \
    --ssl-certfile certs/broker.crt
