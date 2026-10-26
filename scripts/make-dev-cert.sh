#!/bin/sh
# Creates a local self-signed code-signing certificate "Windows Manager Dev" in a project keychain
# (.signing/dev.keychain-db, git-ignored). Signing every build with it keeps the app's identity stable,
# so the Accessibility permission survives rebuilds. No Apple account needed; the login keychain and the
# keychain search list are left as they were.
set -e
cd "$(dirname "$0")/.."

DIR=.signing
KC="$PWD/$DIR/dev.keychain-db"
NAME="Windows Manager Dev"

if [ -f "$KC" ]; then
    echo "Already set up: $KC"
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
PW=$(/usr/bin/openssl rand -hex 16)
printf '%s' "$PW" > "$DIR/keychain-password"
chmod 600 "$DIR/keychain-password"

cat > "$DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/cert.cnf" \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" \
    -out "$DIR/dev.p12" -passout "pass:$PW"

# create-keychain may add the new keychain to the search list; put the list back afterwards.
OLD_LIST=$(security list-keychains -d user | tr -d '"')
security create-keychain -p "$PW" "$KC"
# shellcheck disable=SC2086
security list-keychains -d user -s $OLD_LIST
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$DIR/dev.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
rm -f "$DIR/dev.p12" "$DIR/key.pem"

echo "Created \"$NAME\" in $KC"
