#!/usr/bin/env python3
"""Exercise the gateway policy with ephemeral signing keys and a fake backend."""
import base64
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ISSUER = "https://issuer.actorjwt.test"
AUDIENCE = "kagent-tools-mcp"


def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def openssl(*args, data=None):
    return subprocess.run(
        ["openssl", *map(str, args)], input=data, capture_output=True, check=True
    ).stdout


def generate_key(path):
    openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", path)
    modulus = openssl("rsa", "-in", path, "-noout", "-modulus").decode().strip()
    return {"kty": "RSA", "alg": "RS256", "kid": "test", "e": "AQAB",
            "n": encode(bytes.fromhex(modulus.split("=", 1)[1]))}


def sign(path, claims):
    header = {"alg": "RS256", "kid": "test", "typ": "JWT"}
    prefix = ".".join(encode(json.dumps(part).encode()) for part in (header, claims))
    signature = openssl("dgst", "-sha256", "-sign", path, data=prefix.encode())
    return f"{prefix}.{encode(signature)}"


def status(port, token=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        headers = {} if token is None else {"Authorization": f"Bearer {token}"}
        conn.request("POST", "/mcp", body=b"{}", headers=headers)
        response = conn.getresponse()
        response.read()
        return response.status
    finally:
        conn.close()


def run(image, port):
    calls = []
    source = Path(__file__).resolve().parents[2] / "hardening/actorjwt/gateway.yaml"
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory)
        private_key = temp / "test.key"
        other_key = temp / "other.key"
        jwk = generate_key(private_key)
        generate_key(other_key)

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({"keys": [jwk]}).encode())

            def do_POST(self):
                calls.append("Authorization" in self.headers)
                self.send_response(204)
                self.end_headers()

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            backend = f"127.0.0.1:{server.server_port}"
            config = source.read_text().replace("port: 8080", f"port: {port}")
            config = config.replace("https://idp.ate-system.svc/openid/v1/jwks", f"http://{backend}/jwks")
            config = config.replace("https://idp.ate-system.svc", ISSUER)
            config = config.replace("kagent-tools.kagent.svc.cluster.local:8084", backend)
            config_path = temp / "gateway.yaml"
            config_path.write_text(config)
            name = f"actorjwt-test-{os.getpid()}"
            command = ["docker", "run", "--rm", "--name", name, "--network", "host",
                       "-v", f"{config_path}:/gateway.yaml:ro", image, "-f", "/gateway.yaml"]
            try:
                with (temp / "gateway.log").open("w") as log:
                    process = subprocess.Popen(command, stdout=log, stderr=log)
                    for _ in range(60):
                        if process.poll() is not None:
                            raise RuntimeError((temp / "gateway.log").read_text())
                        try:
                            if status(port) == 401:
                                break
                        except OSError:
                            pass
                        time.sleep(0.25)
                    else:
                        raise RuntimeError("Gateway did not start or reject unauthenticated traffic")
                    now = int(time.time())
                    claims = {"iss": ISSUER, "aud": [AUDIENCE], "sub": "actor/test/session",
                              "iat": now, "nbf": now - 1, "exp": now + 300}
                    cases = [
                        ("valid", sign(private_key, claims), 204),
                        ("missing", None, 401),
                        ("invalid signature", sign(other_key, claims), 401),
                        ("wrong issuer", sign(private_key, dict(claims, iss="https://other.test")), 401),
                        ("wrong audience", sign(private_key, dict(claims, aud=["other"])), 401),
                        ("expired", sign(private_key, dict(claims, exp=now - 3600)), 401),
                    ]
                    for label, token, expected in cases:
                        actual = status(port, token)
                        if actual != expected:
                            raise AssertionError(f"{label}: expected HTTP {expected}, got {actual}")
                        print(f"OK {label}: HTTP {actual}")
                    if calls != [False]:
                        raise AssertionError("Only the valid request may reach the backend, without its JWT")
                    print("OK backend received only the accepted request, without Authorization")
            finally:
                subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)
                server.shutdown()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(f"Usage: {sys.argv[0]} AGENTGATEWAY_IMAGE LOCAL_PORT")
    run(sys.argv[1], int(sys.argv[2]))
