#!/usr/bin/env bash
# Não permita que bash -x revele a senha lida ou o SQL expandido.
set +x
set +v
set -Eeuo pipefail

uso() {
    printf 'Uso: %s --password-stdin APP_IP BASE USUARIO (senha de uma linha no stdin)\n' "$0" >&2
    exit 2
}

erro() {
    printf 'Erro: %s\n' "$*" >&2
    exit 1
}

validar_ipv4() {
    local endereco=$1
    local octeto
    local -a octetos

    [[ $endereco =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octetos <<< "$endereco"
    (( ${#octetos[@]} == 4 )) || return 1

    for octeto in "${octetos[@]}"; do
        (( 10#$octeto <= 255 )) || return 1
    done
}

validar_identificador() {
    local identificador=$1

    (( ${#identificador} >= 1 && ${#identificador} <= 64 )) || return 1
    [[ $identificador =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

(( $# == 4 )) || uso
[[ $EUID -eq 0 ]] || erro 'este script precisa ser executado como root'
[[ $1 == --password-stdin ]] || uso
shift

APP_IP=$1
BASE=$2
USUARIO=$3

validar_ipv4 "$APP_IP" || erro 'APP_IP deve ser um endereço IPv4 válido'
validar_identificador "$BASE" || erro 'BASE deve ser um identificador de banco MariaDB válido'
validar_identificador "$USUARIO" || erro 'USUARIO deve ser um identificador de usuário MariaDB válido'
# A chamada antiga com senha em argv é rejeitada sem reproduzir os argumentos.
[[ ! -t 0 ]] || erro 'transmita a senha por stdin não interativo'
unset SENHA DB_PASS DB_PASS_PROD DB_PASS_DEV
SENHA=
IFS= read -r SENHA || [[ -n $SENHA ]] || erro 'stdin não forneceu uma senha'
EXTRA=
if IFS= read -r EXTRA || [[ -n $EXTRA ]]; then
    erro 'stdin deve conter somente uma linha de senha'
fi
[[ -n $SENHA ]] || erro 'SENHA não pode ser vazia'
[[ $SENHA =~ ^[A-Za-z0-9_@%+=.,:-]+$ ]] || \
    erro 'SENHA contém caracteres não permitidos (use apenas alfanuméricos, _ @ % + = . : , -)'

MARIADB_CONFIG=/etc/mysql/mariadb.conf.d/50-server.cnf
[[ -f $MARIADB_CONFIG ]] || erro "configuração não encontrada: $MARIADB_CONFIG"
[[ -d /var/lib/mysql ]] || erro 'o diretório de dados /var/lib/mysql não está montado ou não existe'

command -v systemctl >/dev/null 2>&1 || erro 'systemctl não está disponível'
command -v mariadb >/dev/null 2>&1 || erro 'cliente mariadb não está disponível'

# O volume pode ter sido montado com proprietário do container anterior.
chown -R mysql:mysql /var/lib/mysql
chmod 0750 /var/lib/mysql

if grep -Eq '^[[:space:]]*bind-address[[:space:]]*=' "$MARIADB_CONFIG"; then
    sed -Ei 's/^[[:space:]]*bind-address[[:space:]]*=.*/bind-address = 0.0.0.0/' "$MARIADB_CONFIG"
else
    printf '\n[mysqld]\nbind-address = 0.0.0.0\n' >> "$MARIADB_CONFIG"
fi

if systemctl is-active --quiet mariadb; then
    systemctl stop mariadb
fi
systemctl start mariadb
systemctl is-active --quiet mariadb || erro 'o serviço MariaDB não ficou ativo'
mariadb --protocol=socket --batch --skip-column-names -e 'SELECT 1' >/dev/null || \
    erro 'o serviço MariaDB não respondeu a uma consulta local'

# Os valores usados nesta consulta foram validados acima. A senha não é impressa
# nem passada na linha de comando do cliente; ela segue apenas pelo stdin.
# Erros do cliente podem incluir o SQL: suprima essa saída e informe erro genérico.
if ! mariadb --protocol=socket --batch --skip-column-names >/dev/null 2>&1 <<SQL
CREATE DATABASE IF NOT EXISTS \`$BASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$USUARIO'@'$APP_IP' IDENTIFIED BY '$SENHA';
ALTER USER '$USUARIO'@'$APP_IP' IDENTIFIED BY '$SENHA';
GRANT ALL PRIVILEGES ON \`$BASE\`.* TO '$USUARIO'@'$APP_IP';
FLUSH PRIVILEGES;
SQL
then
    erro 'falha ao aplicar a configuração MariaDB; SQL com credenciais não foi registrado'
fi
unset SENHA EXTRA

printf 'MariaDB configurado para a aplicação em %s.\n' "$APP_IP"
