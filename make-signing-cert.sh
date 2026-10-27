#!/bin/bash
# Один раз: самоподписанный сертификат для подписи MicToggle в login-связке ключей.
# С ним build.sh подписывает приложение постоянной подписью, и разрешение «Универсальный доступ»
# не слетает после каждой пересборки (с ad-hoc подписью слетает). Доверие сертификату не нужно —
# build.sh подписывает по SHA-1 сертификата. Копия ключа — ~/.config/mictoggle-signing (600).
set -euo pipefail
NAME="MicToggle Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "уже есть: $NAME"
  exit 0
fi
D=~/.config/mictoggle-signing
mkdir -p "$D" && chmod 700 "$D" && cd "$D"
cat > cert.cnf <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem -config cert.cnf 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out signing.p12 -passout "pass:$PASS"
chmod 600 ./*
security import signing.p12 -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
echo "готово: $NAME"
