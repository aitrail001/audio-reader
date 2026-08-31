#!/usr/bin/env bash
set -euo pipefail

API="${AUDIOREADER_API_BASE_URL:-http://127.0.0.1:8787}"
OTP="${LOCAL_DEV_OTP:-123456}"
EMAIL="${E2E_EMAIL:-}"
DEVICE_ID="${E2E_DEVICE_ID:-}"
TIMEOUT_SECONDS="${E2E_TIMEOUT_SECONDS:-90}"

export API OTP EMAIL DEVICE_ID TIMEOUT_SECONDS

python3 - <<'PY'
import base64
import hashlib
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

api = os.environ["API"].rstrip("/")
otp = os.environ["OTP"]
email = os.environ.get("EMAIL") or f"local-e2e-{int(time.time())}@example.com"
device_id = os.environ.get("DEVICE_ID") or "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa%02x" % (int(time.time()) % 256)
timeout = int(os.environ["TIMEOUT_SECONDS"])


def request(method, path, body=None, headers=None):
    data = None
    req_headers = {"X-Request-Id": "local-e2e", "Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        req_headers["Content-Type"] = "application/json"
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(f"{api}{path}", data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode("utf-8")
            try:
                parsed = json.loads(raw) if raw else None
            except json.JSONDecodeError:
                parsed = raw
            return response.status, parsed, raw
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8")
        try:
            parsed = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            parsed = raw
        return error.code, parsed, raw


def require(ok: bool, message: str) -> None:
    if not ok:
        print(message, file=sys.stderr)
        sys.exit(1)


print(f"waiting for {api}/healthz ...")
deadline = time.time() + timeout
status = 0
payload = None
raw = ""
while time.time() < deadline:
    try:
        status, payload, raw = request("GET", "/healthz")
        if status == 200:
            break
    except OSError:
        status = 0
    time.sleep(1)
require(status == 200, f"timed out waiting for {api}/healthz")

status, payload, raw = request("GET", "/v1/health")
require(status == 200 and isinstance(payload, dict), f"GET /v1/health failed: {status} {raw}")

status, payload, raw = request("GET", "/v1/auth/config")
require(status == 200 and isinstance(payload, dict), f"GET /v1/auth/config failed: {status} {raw}")
ids = [item.get("id") for item in payload.get("providers", [])] if isinstance(payload.get("providers"), list) else []
require("email_otp" in ids, f"auth config missing email_otp: {raw}")

status, payload, raw = request("POST", "/v1/auth/email-otp/request", {"email": email})
require(status == 202, f"OTP request failed: {status} {raw}")

status, payload, raw = request(
    "POST",
    "/v1/auth/email-otp/verify",
    {"email": email, "code": otp, "deviceId": device_id},
)
require(status == 200 and isinstance(payload, dict), f"OTP verify failed: {status} {raw}")
access = payload.get("accessToken")
require(isinstance(access, str) and access != "", f"missing accessToken: {raw}")

auth = {"Authorization": f"Bearer {access}", "X-Device-Id": device_id}
status, payload, raw = request(
    "POST",
    "/v1/auth/bootstrap",
    {"deviceId": device_id, "platform": "macos", "appVersion": "2.0.0", "buildNumber": "91"},
    {**auth, "Idempotency-Key": "local-e2e-bootstrap-01"},
)
require(status in {200, 201}, f"bootstrap failed: {status} {raw}")

status, payload, raw = request("GET", "/v1/me", headers=auth)
require(status == 200 and isinstance(payload, dict) and payload.get("email") == email, f"GET /v1/me failed: {status} {raw}")

status, payload, raw = request("GET", "/v1/me/devices", headers=auth)
require(status == 200, f"GET /v1/me/devices failed: {status} {raw}")

verifier_bytes = os.urandom(32)
verifier = base64.urlsafe_b64encode(verifier_bytes).rstrip(b"=").decode()
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
status, payload, raw = request(
    "POST",
    "/v1/auth/oauth/authorize",
    {
        "provider": "google",
        "redirectUri": "audioreader://auth/callback",
        "codeChallenge": challenge,
        "codeChallengeMethod": "S256",
        "state": "oauth-e2e-state",
    },
)
require(status == 200 and isinstance(payload, dict), f"OAuth authorize failed: {status} {raw}")
authorization_url = payload.get("authorizationUrl")
require(isinstance(authorization_url, str) and "/v1/auth/oauth/local-complete" in authorization_url, f"OAuth authorize URL was not local-complete: {raw}")
parsed_api = urllib.parse.urlparse(api)
parsed_auth = urllib.parse.urlparse(authorization_url)
conn = http.client.HTTPConnection(parsed_api.hostname, parsed_api.port or 80, timeout=30)
path = parsed_auth.path
if parsed_auth.query:
    path += "?" + parsed_auth.query
conn.request("GET", path, headers={"X-Request-Id": "local-e2e"})
oauth_response = conn.getresponse()
location = oauth_response.getheader("Location")
oauth_response.read()
conn.close()
require(oauth_response.status == 302, f"local OAuth complete status {oauth_response.status}")
require(isinstance(location, str) and location.startswith("audioreader://auth/callback"), f"local OAuth complete location {location}")

print(f"local API end-to-end checks passed against {api}")
PY
