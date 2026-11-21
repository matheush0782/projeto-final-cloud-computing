#!/usr/bin/env bash
set -euo pipefail
# Compativel com scripts/common.sh da PR #1: ENV=prod (8444) ou ENV=dev (8445).
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
carregar_config
exigir_comandos lxc python3 openssl curl sed grep mktemp
checar_lxd

validar_ipv4() {
    local ip="$1" octeto
    local -a octetos
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octetos <<< "$ip"
    (( ${#octetos[@]} == 4 )) || return 1
    for octeto in "${octetos[@]}"; do
        [[ "$octeto" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#$octeto <= 255 )) || return 1
    done
}

if [[ -z "${IP_VM:-}" ]]; then
    read -rp 'IP IPv4 real da VM (para SAN do certificado): ' IP_VM
fi
if [[ -z "${IP_SITE:-}" ]]; then
    read -rp 'IP usado no navegador [127.0.0.1]: ' IP_SITE
fi
IP_SITE="${IP_SITE:-127.0.0.1}"
validar_ipv4 "$IP_VM" || falhar 'IP_VM deve ser IPv4 valido (ex.: 10.0.2.15).'
validar_ipv4 "$IP_SITE" || falhar 'IP_SITE deve ser IPv4 valido (ex.: 127.0.0.1).'

PROXY="${PREFIXO}proxy"
APP="${PREFIXO}app"
lx info "$PROXY" >/dev/null
lx info "$APP" >/dev/null
[[ -f "$RAIZ/conf/nginx-servico-https.conf" ]] || falhar 'Template do Nginx HTTPS ausente.'
[[ -f "$RAIZ/conf/atualiza-url-wp.php" ]] || falhar 'Script PHP para alterar URLs ausente.'

# Cada ambiente recebe sua propria CA e seu certificado (sem enviar chaves ao GitHub).
TLS_DIR="$RAIZ/conf/tls/$ENV"
umask 077
mkdir -p -m 700 "$TLS_DIR"
chmod 700 "$TLS_DIR"

if [[ -f "$TLS_DIR/ca.key" && -f "$TLS_DIR/ca.crt" && \
      -f "$TLS_DIR/servico.key" && -f "$TLS_DIR/servico.crt" ]]; then
    echo "Certificados existentes em $TLS_DIR: serao reutilizados."
elif [[ -e "$TLS_DIR/ca.key" || -e "$TLS_DIR/ca.crt" || \
        -e "$TLS_DIR/servico.key" || -e "$TLS_DIR/servico.crt" ]]; then
    falhar 'Certificados incompletos: preservados para verificacao manual. Nao sobregrave as chaves.'
else
    TMP_TLS="$(mktemp -d "$TLS_DIR/.gerando.XXXXXX")"
    trap 'rm -rf -- "${TMP_TLS:-}"' EXIT
    openssl genrsa -out "$TMP_TLS/ca.key" 4096
    openssl req -x509 -new -key "$TMP_TLS/ca.key" -sha256 -days 365 \
        -subj "/CN=CA da Equipe - $PROJETO - $ENV" \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -out "$TMP_TLS/ca.crt"
    openssl genrsa -out "$TMP_TLS/servico.key" 2048
    openssl req -new -key "$TMP_TLS/servico.key" \
        -subj "/CN=servico.lab" -out "$TMP_TLS/servico.csr"
    cat > "$TMP_TLS/san.ext" <<EOF_SAN
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:servico.lab,IP:$IP_VM,IP:$IP_SITE,IP:127.0.0.1
EOF_SAN
    openssl x509 -req -in "$TMP_TLS/servico.csr" \
        -CA "$TMP_TLS/ca.crt" -CAkey "$TMP_TLS/ca.key" -CAcreateserial \
        -out "$TMP_TLS/servico.crt" -days 365 -sha256 \
        -extfile "$TMP_TLS/san.ext"
    openssl verify -CAfile "$TMP_TLS/ca.crt" "$TMP_TLS/servico.crt"
    for nome in ca.key ca.crt servico.key servico.crt servico.csr san.ext; do
        mv -- "$TMP_TLS/$nome" "$TLS_DIR/$nome"
    done
    rm -rf -- "$TMP_TLS"
    unset TMP_TLS
    trap - EXIT
fi

# Certificado valido e coerente com os enderecos atuais.
openssl verify -CAfile "$TLS_DIR/ca.crt" "$TLS_DIR/servico.crt" >/dev/null
cmp -s <(openssl pkey -in "$TLS_DIR/servico.key" -pubout) \
       <(openssl x509 -in "$TLS_DIR/servico.crt" -pubkey -noout) || \
       falhar 'Chave e certificado do servico nao correspondem.'
chmod 0600 "$TLS_DIR/ca.key" "$TLS_DIR/servico.key"
SAN="$(openssl x509 -in "$TLS_DIR/servico.crt" -noout -ext subjectAltName | tr ',' '\n' | sed 's/^[[:space:]]*//')"
for IP in "$IP_VM" "$IP_SITE" 127.0.0.1; do
    grep -Fxq "IP Address:$IP" <<< "$SAN" || falhar "Certificado existente nao cobre IP:$IP. Ajuste a CA/certificado com a equipe, sem sobrescrever chaves." 
done

# Mesmo caminho para PR #1 e Fase 5.
lx exec "$PROXY" -- install -d -m 0700 /etc/nginx/ssl
lx file push "$TLS_DIR/servico.crt" "$PROXY/etc/nginx/ssl/servico.crt" --mode 0644
lx file push "$TLS_DIR/servico.key" "$PROXY/etc/nginx/ssl/servico.key" --mode 0600

# Renderiza a configuracao para PROD ou DEV sem alterar o template versionado.
TMP_CONF="$(mktemp)"
trap 'rm -f -- "$TMP_CONF"' EXIT
sed -e "s/__APP_IP__/${SUBNET}.11/g" \
    -e "s/__HTTPS_PORT__/${PORTA_HTTPS}/g" \
    "$RAIZ/conf/nginx-servico-https.conf" > "$TMP_CONF"
if grep -qE '__APP_IP__|__HTTPS_PORT__' "$TMP_CONF"; then
    falhar 'O template HTTPS nao foi totalmente renderizado.'
fi
lx file push "$TMP_CONF" "$PROXY/etc/nginx/sites-available/servico"
lx exec "$PROXY" -- bash -c '
    set -e
    ln -sfn /etc/nginx/sites-available/servico /etc/nginx/sites-enabled/servico
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl reload nginx
'

# Dispositivo HTTPS: nao criar se ja existe; conferir ou atualizar.
LISTEN="tcp:0.0.0.0:$PORTA_HTTPS"
CONNECT='tcp:127.0.0.1:443'
if lx config device list "$PROXY" | grep -Fxq 'porta-https'; then
    TIPO="$(lx config device get "$PROXY" porta-https type)"
    [[ "$TIPO" == proxy ]] || falhar "O dispositivo porta-https existente nao e tipo proxy ($TIPO)."
    ATUAL_LISTEN="$(lx config device get "$PROXY" porta-https listen)"
    ATUAL_CONNECT="$(lx config device get "$PROXY" porta-https connect)"
    if [[ "$ATUAL_LISTEN" != "$LISTEN" || "$ATUAL_CONNECT" != "$CONNECT" ]]; then
        lx config device set "$PROXY" porta-https listen="$LISTEN" connect="$CONNECT"
        echo 'Dispositivo porta-https atualizado.'
    else
        echo 'Dispositivo porta-https ja correto; nenhuma duplicacao.'
    fi
else
    lx config device add "$PROXY" porta-https proxy \
        listen="$LISTEN" connect="$CONNECT"
fi

# Ajusta duas constantes com PHP, preservando espacos e aspas da instalacao da PR #1.
lx file push "$RAIZ/conf/atualiza-url-wp.php" "$APP/root/atualiza-url-wp.php" --mode 0644
lx exec "$APP" -- php -l /root/atualiza-url-wp.php
lx exec "$APP" -- env "WP_SITE_URL=https://${IP_SITE}:${PORTA_HTTPS}" \
    php /root/atualiza-url-wp.php

# O teste valida a CA de verdade (sem -k / --insecure).
URL_TESTE="https://${IP_SITE}:${PORTA_HTTPS}/"
if [[ "$IP_SITE" == 127.0.0.1 ]]; then
    curl --fail --silent --show-error --head --cacert "$TLS_DIR/ca.crt" "$URL_TESTE"
else
    curl --fail --silent --show-error --head --cacert "$TLS_DIR/ca.crt" \
        --resolve "${IP_SITE}:${PORTA_HTTPS}:127.0.0.1" "$URL_TESTE"
fi
printf '\nOK: teste HTTPS de %s feito com a CA local.\n' "$URL_TESTE"
printf 'Para navegador externo, copie APENAS o certificado publico: %s/ca.crt\n' "$TLS_DIR"
