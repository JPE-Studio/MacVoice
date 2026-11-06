#!/bin/bash
# One-time: create a stable self-signed codesigning certificate so macOS TCC
# keeps granting permissions across rebuilds (instead of ad-hoc signatures that
# change every build).
set -euo pipefail
NAME="MacVoiceDev"

security find-identity -v -p codesigning | grep -q "$NAME" && { echo "cert '$NAME' already exists"; exit 0; }

cat > /tmp/macvoice-cert.tmpl <<EOF
[ req ]
default_bits = 2048
distinguished_name = req_dn
prompt = no
[ req_dn ]
CN = $NAME
O = Petermaier
C = AT
[ req_ext ]
basicConstraints = critical,CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/macvoice-key.pem \
    -out /tmp/macvoice-cert.pem -days 3650 -config /tmp/macvoice-cert.tmpl -extensions req_ext

openssl pkcs12 -export -out /tmp/macvoice-cert.p12 \
    -inkey /tmp/macvoice-key.pem -in /tmp/macvoice-cert.pem -password pass:macvoice

security import /tmp/macvoice-cert.p12 -k ~/Library/Keychains/login.keychain-db \
    -P macvoice -T /usr/bin/codesign

rm -f /tmp/macvoice-cert.tmpl /tmp/macvoice-key.pem /tmp/macvoice-cert.pem /tmp/macvoice-cert.p12
echo "cert '$NAME' created — grant it codesigning trust if macOS asks (System Settings prompt)."
