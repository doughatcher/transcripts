#!/usr/bin/env python3
"""GET an App Store Connect endpoint and print the JSON.

    set -a && . ./.env.signing && set +a
    python3 scripts/asc.py "apps/<id>/appStoreVersions?limit=3"

No third-party packages. PyJWT is the usual way to mint the ES256 token, but it
is not installed here and adding it to answer one question is a poor trade — so
`openssl` signs instead. The only fiddly part is that openssl emits a DER
SEQUENCE of two INTEGERs while JWS wants their raw 32-byte big-endian
concatenation, which is what `_der_to_raw` unpacks.

The .p8 signs the token and is never printed.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _der_to_raw(der: bytes, size: int = 32) -> bytes:
    """DER SEQUENCE{INTEGER r, INTEGER s} -> r||s, each left-padded to `size`."""
    if der[0] != 0x30:
        raise ValueError("not a DER sequence")
    # Skip SEQUENCE tag and its length (short or long form).
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("expected INTEGER")
        length = der[i + 1]
        val = der[i + 2:i + 2 + length]
        # DER prefixes a 0x00 when the high bit would read as negative.
        val = val.lstrip(b"\x00")
        out += val.rjust(size, b"\x00")
        i += 2 + length
    return out


def token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    key_path = os.path.expanduser(os.environ["ASC_KEY_PATH"])

    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 900,
               "aud": "appstoreconnect-v1"}
    signing_input = f"{b64(json.dumps(header).encode())}." \
                    f"{b64(json.dumps(payload).encode())}"

    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{b64(_der_to_raw(der))}"


def main() -> int:
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com/v1/" + sys.argv[1],
        headers={"Authorization": f"Bearer {token()}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(json.dumps(json.load(r), indent=1))
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:600]}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
