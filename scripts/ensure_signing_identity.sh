#!/bin/bash
# Create a persistent local code-signing identity so TCC (Accessibility / mic)
# survives rebuilds. Ad-hoc (`codesign -s -`) gets a new hash every build →
# macOS treats the app as new and re-prompts.
set -euo pipefail

NAME="Local Whisper Flow Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${NAME}"; then
  echo "Signing identity already present: ${NAME}"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
openssl req -new -key "$TMP/key.pem" -out "$TMP/req.csr" -subj "/CN=${NAME}/O=Local Whisper Flow/C=US"
cat > "$TMP/ext.cnf" <<'EOF'
[v3]
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=codeSigning
EOF
openssl x509 -req -days 3650 -in "$TMP/req.csr" -signkey "$TMP/key.pem" -out "$TMP/cert.pem" \
  -extfile "$TMP/ext.cnf" -extensions v3 2>/dev/null
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:lwf -name "$NAME" 2>/dev/null

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P lwf -T /usr/bin/codesign -T /usr/bin/security \
  -f pkcs12 2>/dev/null || security import "$TMP/cert.p12" -k "$KEYCHAIN" -P lwf -T /usr/bin/codesign

# Allow codesign without keychain UI unlock when possible
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" 2>/dev/null || true

echo "Created signing identity: ${NAME}"
echo "Trust it once: Keychain Access → My Certificates → ${NAME} → Get Info → Trust → Code Signing: Always Trust"
security find-identity -v -p codesigning | grep -F "$NAME" || true
