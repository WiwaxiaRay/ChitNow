#!/usr/bin/env python3
"""
Idempotent first-run setup.
  - Creates broker/config.json with a random API key.
  - Creates broker/certs/broker.key + broker.crt (self-signed, valid 825 days).
Run before every broker start; safe to re-run (skips if already exists).
"""
import datetime
import ipaddress
import json
import os
import secrets
import socket

_DIR        = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(_DIR, "config.json")
CERT_DIR    = os.path.join(_DIR, "certs")
KEY_PATH    = os.path.join(CERT_DIR, "broker.key")
CRT_PATH    = os.path.join(CERT_DIR, "broker.crt")
FP_PATH     = os.path.join(CERT_DIR, "fingerprint.txt")


def ensure_config() -> dict:
    if os.path.exists(CONFIG_PATH):
        try:
            cfg = json.loads(open(CONFIG_PATH).read())
            if cfg.get("api_key"):
                return cfg
        except Exception:
            pass
    cfg = {"api_key": secrets.token_hex(32)}
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_PATH, 0o600)
    print(f"[setup] new API key → {CONFIG_PATH}", flush=True)
    return cfg


def _lan_ips() -> list:
    ips = [ipaddress.IPv4Address("127.0.0.1")]
    try:
        hostname = socket.gethostname()
        for res in socket.getaddrinfo(hostname, None, socket.AF_INET):
            try:
                ips.append(ipaddress.IPv4Address(res[4][0]))
            except Exception:
                pass
    except Exception:
        pass
    # deduplicate, preserving order
    seen, out = set(), []
    for ip in ips:
        if ip not in seen:
            seen.add(ip)
            out.append(ip)
    return out


def ensure_certs() -> str:
    """Returns SHA-256 fingerprint (hex) of the leaf certificate."""
    if os.path.exists(KEY_PATH) and os.path.exists(CRT_PATH) and os.path.exists(FP_PATH):
        return open(FP_PATH).read().strip()

    os.makedirs(CERT_DIR, exist_ok=True)

    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "thenow-broker")])
    san = x509.SubjectAlternativeName(
        [x509.DNSName("localhost")] + [x509.IPAddress(ip) for ip in _lan_ips()]
    )
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=825))
        .add_extension(san, critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )

    with open(KEY_PATH, "wb") as f:
        f.write(key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        ))
    os.chmod(KEY_PATH, 0o600)

    with open(CRT_PATH, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))

    fp = cert.fingerprint(hashes.SHA256()).hex()
    with open(FP_PATH, "w") as f:
        f.write(fp)

    print(f"[setup] TLS cert generated, fingerprint: {fp}", flush=True)
    return fp


if __name__ == "__main__":
    ensure_config()
    ensure_certs()
    print("[setup] done", flush=True)
