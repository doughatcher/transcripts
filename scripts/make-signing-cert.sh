#!/usr/bin/env bash
#
# Create a STABLE self-signed code-signing identity ("Transcripts Local Signing") in the
# login keychain, so macOS TCC binds Microphone / Screen Recording consent to a
# fixed code identity that survives rebuilds.
#
# Why: ad-hoc signing (`codesign --sign -`) regenerates the code identity on every
# compile. TCC then sees a different binary than the one you granted, reports
# `authorized`, but delivers SILENCE to the mic (and no frames to ScreenCaptureKit).
# A fixed identity fixes that permanently — grant once, works across all rebuilds.
#
# No admin rights, no Apple Developer account, no keychain trust dialog needed:
# codesign can sign with an untrusted self-signed cert (trust only matters for
# verification/Gatekeeper, which is irrelevant for a locally-run app).
#
# Idempotent: re-running when the identity already exists is a no-op.

set -euo pipefail

NAME="Transcripts Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ '$NAME' already installed."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/csc.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Transcripts Local Signing
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

echo "▶ Generating self-signed code-signing certificate …"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/transcripts.key" -out "$TMP/transcripts.crt" \
  -days 3650 -config "$TMP/csc.cnf" >/dev/null 2>&1

# OpenSSL 3.x exports PKCS12 with modern encryption that macOS `security import`
# can't parse ("MAC verification failed"); -legacy fixes it. Apple's LibreSSL has no
# -legacy flag but is already compatible, so only add it when it's supported.
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY="-legacy"; fi
openssl pkcs12 -export $LEGACY -inkey "$TMP/transcripts.key" -in "$TMP/transcripts.crt" \
  -out "$TMP/transcripts.p12" -passout pass:transcripts -name "$NAME" >/dev/null 2>&1

echo "▶ Importing into login keychain …"
security import "$TMP/transcripts.p12" -k "$KEYCHAIN" -P transcripts -T /usr/bin/codesign -A >/dev/null

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ '$NAME' installed. Re-run scripts/make-app.sh to sign with it."
  echo "  NOTE: the stale ad-hoc grant must be cleared once so a fresh prompt binds"
  echo "  to the new identity:  tccutil reset Microphone ltd.hatcher.transcripts"
else
  echo "✗ Import reported success but the identity isn't listed; check Keychain Access." >&2
  exit 1
fi
