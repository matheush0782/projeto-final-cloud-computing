
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

read -rp "Identificador da equipe: " EQUIPE
read -rp "IP real da maquina virtual: " IP_VM
read -rp "IP usado no navegador [127.0.0.1]: " IP_SITE

IP_SITE="${IP_SITE:-127.0.0.1}"
PROJETO="final-equipe${EQUIPE}"

lxc project show "$PROJETO" > /dev/null
lxc info proxy --project "$PROJETO" > /dev/null
lxc info app --project "$PROJETO" > /dev/null

# Proteger os arquivos privados
umask 077
mkdir -p conf/tls

cd conf/tls

# Evitar substituir certificados existentes
if [[ -e ca.key || -e servico.key ]]; then
    echo "Chaves existentes. Confira os certificados antes de continuar."
    exit 1
fi

# 1. Criar chave privada da CA
openssl genrsa -out ca.key 4096

# 2. Criar certificado da CA
openssl req -x509 -new \
    -key ca.key \
    -sha256 \
    -days 365 \
    -subj "/CN=CA da Equipe ${EQUIPE}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -out ca.crt

# 3. Criar chave privada do servico
openssl genrsa -out servico.key 2048

# 4. Criar solicitacao do certificado
openssl req -new \
    -key servico.key \
    -subj "/CN=servico.lab" \
    -out servico.csr

# 5. Definir nomes e IPs validos
printf "subjectAltName=DNS:servico.lab,IP:%s,IP:%s,IP:127.0.0.1\n" \
    "$IP_VM" "$IP_SITE" > san.ext

# 6. Assinar o certificado
openssl x509 -req \
    -in servico.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out servico.crt \
    -days 365 \
    -sha256 \
    -extfile san.ext

# Verificar o certificado
openssl verify -CAfile ca.crt servico.crt

cd ../..

# 7. Enviar certificado ao proxy
lxc file push conf/tls/servico.crt \
    proxy/etc/ssl/certs/servico.crt \
    --project "$PROJETO"

lxc file push conf/tls/servico.key \
    proxy/etc/ssl/private/servico.key \
    --mode 0600 \
    --project "$PROJETO"

# 8. Instalar configuracao HTTPS
lxc file push conf/nginx-servico-https.conf \
    proxy/etc/nginx/sites-available/servico \
    --project "$PROJETO"

lxc exec proxy --project "$PROJETO" -- nginx -t

lxc exec proxy --project "$PROJETO" -- \
    systemctl reload nginx

# 9. Publicar porta HTTPS
lxc config device add proxy porta-https proxy \
    listen=tcp:0.0.0.0:8444 \
    connect=tcp:127.0.0.1:443 \
    --project "$PROJETO"

# 10. Atualizar URL do WordPress
lxc exec app --project "$PROJETO" -- \
    sed -i -E \
    "/define\('WP_(HOME|SITEURL)'/s#http://[^']+:8081#https://${IP_SITE}:8444#g" \
    /var/www/html/wp-config.php

# 11. Testar HTTPS
curl --cacert conf/tls/ca.crt \
    --resolve servico.lab:8444:127.0.0.1 \
    -sSI https://servico.lab:8444

echo "Confira o HTTPS em https://${IP_SITE}:8444"
