#!/usr/bin/env bash
# Não permita que bash -x revele a senha ou a configuração gerada.
set +x
set +v
set -Eeuo pipefail
umask 077

uso() {
    printf 'Uso: %s --password-stdin DB_HOST URL [DB_NAME=wordpress] [DB_USER=wpuser] (senha de uma linha no stdin)\n' "$0" >&2
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

validar_dns() {
    local nome=$1

    (( ${#nome} >= 1 && ${#nome} <= 253 )) || return 1
    [[ $nome =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

validar_url() {
    local url=$1
    local host
    local porta

    [[ $url =~ ^https?://([^/:?#]+)(:([0-9]{1,5}))?/?$ ]] || return 1
    host=${BASH_REMATCH[1]}
    porta=${BASH_REMATCH[3]:-}

    if [[ -n $porta ]]; then
        (( porta >= 1 && porta <= 65535 )) || return 1
    fi

    # Um endereço com quatro componentes exclusivamente numéricos deve ser
    # IPv4 de fato; não o tratamos como um nome DNS para mascarar octeto ruim.
    if [[ $host =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        validar_ipv4 "$host"
        return
    fi

    validar_ipv4 "$host" || validar_dns "$host"
}

(( $# >= 3 && $# <= 5 )) || uso
[[ $EUID -eq 0 ]] || erro 'este script precisa ser executado como root'
[[ $1 == --password-stdin ]] || uso
shift

DB_HOST=$1
URL=$2
DB_NAME=${3:-wordpress}
DB_USER=${4:-wpuser}

[[ $DB_HOST =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || \
    erro 'DB_HOST contém caracteres não permitidos'
# Não aceite senha em argv nem exporte credenciais herdadas aos comandos filhos.
[[ ! -t 0 ]] || erro 'transmita a senha por stdin não interativo'
unset DB_PASS DB_PASS_PROD DB_PASS_DEV
DB_PASS=
IFS= read -r DB_PASS || [[ -n $DB_PASS ]] || erro 'stdin não forneceu uma senha'
EXTRA=
if IFS= read -r EXTRA || [[ -n $EXTRA ]]; then
    erro 'stdin deve conter somente uma linha de senha'
fi
[[ -n $DB_PASS && $DB_PASS != *$'\n'* && $DB_PASS != *$'\r'* ]] || \
    erro 'DB_PASS deve ser não vazia e não conter quebras de linha'
validar_identificador "$DB_NAME" || erro 'DB_NAME deve ser um identificador válido'
validar_identificador "$DB_USER" || erro 'DB_USER deve ser um identificador válido'
validar_url "$URL" || erro 'URL deve ser http(s)://host, com host IPv4 ou DNS e porta opcional'

# O WordPress usa URLs canônicas sem a barra final; uma eventual barra única
# aceita pela validação é removida antes de ser gravada no wp-config.php.
URL_CANONICA=${URL%/}

command -v php >/dev/null 2>&1 || erro 'PHP CLI não está disponível'
command -v systemctl >/dev/null 2>&1 || erro 'systemctl não está disponível'
command -v a2enconf >/dev/null 2>&1 || erro 'a2enconf não está disponível'
command -v apache2ctl >/dev/null 2>&1 || erro 'apache2ctl não está disponível'

DOCROOT=/var/www/html
UPLOADS_DIR=$DOCROOT/wp-content/uploads
TEMP_DIR=$(mktemp -d /tmp/instala-wp.XXXXXX)

limpar() {
    rm -rf -- "$TEMP_DIR"
}
trap limpar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$DOCROOT"

CORE_DIR=
if [[ -f $DOCROOT/wp-includes/version.php && \
      -f $DOCROOT/wp-admin/index.php && \
      -f $DOCROOT/wp-config-sample.php ]]; then
    printf 'Core WordPress existente preservado em %s.\n' "$DOCROOT"
else
    command -v curl >/dev/null 2>&1 || erro 'curl não está disponível'
    command -v tar >/dev/null 2>&1 || erro 'tar não está disponível'

    ARQUIVO="$TEMP_DIR/wordpress.tar.gz"
    # --proto impede downgrade para HTTP; --tlsv1.2 exige TLS moderno. Os
    # retries cobrem falhas transitórias sem revelar segredo de banco.
    curl --fail --show-error --silent --location \
        --proto '=https' --tlsv1.2 \
        --retry 5 --retry-delay 2 --retry-all-errors \
        --connect-timeout 15 --max-time 300 \
        --output "$ARQUIVO" https://wordpress.org/latest.tar.gz

    tar --extract --gzip --file "$ARQUIVO" --directory "$TEMP_DIR" --no-same-owner
    CORE_DIR=$TEMP_DIR/wordpress
    [[ -d $CORE_DIR && -f $CORE_DIR/wp-config-sample.php ]] || \
        erro 'o pacote baixado não tem a estrutura esperada do WordPress'

    instalar_core() {
        local origem
        local nome
        local destino
        local -a entradas

        shopt -s nullglob
        entradas=("$CORE_DIR"/*)
        shopt -u nullglob

        for origem in "${entradas[@]}"; do
            nome=${origem##*/}
            destino=$DOCROOT/$nome

            # wp-content contém conteúdo do site e uploads persistentes;
            # wp-config também é preservado e atualizado separadamente.
            case $nome in
                wp-content|wp-config.php|wp-config-sample.php)
                    continue
                    ;;
            esac

            if [[ -d $origem ]]; then
                # wp-admin e wp-includes são exclusivamente core. Eles podem
                # ser substituídos para que uma recriação receba o core mais
                # recente; nenhum conteúdo de wp-content é removido.
                if [[ $nome == wp-admin || $nome == wp-includes ]]; then
                    rm -rf -- "$destino"
                elif [[ -e $destino && ! -d $destino ]]; then
                    rm -f -- "$destino"
                fi
                cp -a -- "$origem" "$DOCROOT/"
            else
                # Arquivos do core são atualizados; arquivos que não existem
                # no pacote, inclusive conteúdo criado pelo usuário, ficam.
                install -m 0644 "$origem" "$destino"
            fi
        done

        # O mount de uploads já cria wp-content antes da instalação. Copiamos
        # somente os itens padrão ausentes, sem substituir diretórios existentes.
        mkdir -p "$DOCROOT/wp-content"
        for origem in "$CORE_DIR/wp-content/"*; do
            [[ -e $origem ]] || continue
            nome=${origem##*/}
            [[ $nome != uploads ]] || continue
            destino=$DOCROOT/wp-content/$nome
            if [[ ! -e $destino && ! -L $destino ]]; then
                cp -a -- "$origem" "$destino"
            fi
        done
        if [[ ! -f $DOCROOT/wp-config-sample.php ]]; then
            install -m 0644 "$CORE_DIR/wp-config-sample.php" "$DOCROOT/wp-config-sample.php"
        fi
    }

    instalar_core
fi

CONFIG_DESTINO=$DOCROOT/wp-config.php
if [[ -f $CONFIG_DESTINO ]]; then
    CONFIG_ORIGEM=$CONFIG_DESTINO
else
    if [[ -n $CORE_DIR ]]; then
        CONFIG_ORIGEM=$CORE_DIR/wp-config-sample.php
    else
        CONFIG_ORIGEM=$DOCROOT/wp-config-sample.php
    fi
fi
[[ -f $CONFIG_ORIGEM ]] || erro 'wp-config-sample.php não encontrado'

CONFIG_NOVO="$TEMP_DIR/wp-config.php"
# O código PHP chega por stdin e os valores chegam por ambiente. var_export
# gera literais PHP corretos sem interpolação ou injeção por sed; a saída fica
# em arquivo temporário com umask restritiva, nunca no log.
WP_DB_NAME="$DB_NAME" \
WP_DB_USER="$DB_USER" \
WP_DB_PASS="$DB_PASS" \
WP_DB_HOST="$DB_HOST" \
WP_SITE_URL="$URL_CANONICA" \
php /dev/stdin "$CONFIG_ORIGEM" > "$CONFIG_NOVO" <<'PHP'
<?php
declare(strict_types=1);

$origem = $argv[1] ?? '';
if ($origem === '' || !is_readable($origem)) {
    fwrite(STDERR, "Não foi possível ler o wp-config de origem.\n");
    exit(1);
}

$conteudo = file_get_contents($origem);
if ($conteudo === false) {
    fwrite(STDERR, "Não foi possível carregar o wp-config de origem.\n");
    exit(1);
}

$valores = [
    'DB_NAME' => getenv('WP_DB_NAME'),
    'DB_USER' => getenv('WP_DB_USER'),
    'DB_PASSWORD' => getenv('WP_DB_PASS'),
    'DB_HOST' => getenv('WP_DB_HOST'),
    'WP_HOME' => getenv('WP_SITE_URL'),
    'WP_SITEURL' => getenv('WP_SITE_URL'),
];
$faltantes = [];

foreach ($valores as $nome => $valor) {
    if ($valor === false) {
        fwrite(STDERR, "Variável de ambiente ausente para o wp-config.\n");
        exit(1);
    }

    $literal = var_export($valor, true);
    $linha = "define( " . var_export($nome, true) . ", " . $literal . " );";
    $padrao = '/^[ \\t]*define\\s*\\(\\s*[\'\"]' . preg_quote($nome, '/') . '[\'\"]\\s*,.*?\\);[ \\t]*$/m';
    $atualizado = preg_replace_callback($padrao, static fn() => $linha, $conteudo, -1, $quantidade);
    if ($atualizado === null) {
        fwrite(STDERR, "Falha ao atualizar uma constante do wp-config.\n");
        exit(1);
    }

    $conteudo = $atualizado;
    if ($quantidade === 0) {
        $faltantes[] = $linha;
    }
}

if (!empty($faltantes)) {
    $bloco = implode(PHP_EOL, $faltantes) . PHP_EOL;
    $posicao = strpos($conteudo, "/* That's all");
    if ($posicao === false) {
        $posicao = strpos($conteudo, 'require_once ABSPATH');
    }
    if ($posicao === false) {
        $conteudo .= PHP_EOL . $bloco;
    } else {
        $conteudo = substr($conteudo, 0, $posicao) . $bloco . substr($conteudo, $posicao);
    }
}

// Troca somente as frases padrão do sample; preserva chaves existentes.
foreach (['AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY',
          'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT'] as $nome) {
    $padrao = '/^[ \\t]*define\\s*\\(\\s*[\'\"]' . $nome . '[\'\"]\\s*,\\s*[\'\"]put your unique phrase here[\'\"]\\s*\\);[ \\t]*$/m';
    $conteudo = preg_replace_callback($padrao, static fn() =>
        "define( " . var_export($nome, true) . ", " . var_export(bin2hex(random_bytes(48)), true) . " );", $conteudo);
}

echo $conteudo;
PHP
unset DB_PASS EXTRA

install -m 0640 "$CONFIG_NOVO" "$CONFIG_DESTINO"

# O volume de uploads é persistente: somente garantimos que ele exista e que
# o Apache possa gravar nele; nenhum arquivo é apagado ou substituído aqui.
install -d -o www-data -g www-data -m 0755 "$UPLOADS_DIR"
chown -R www-data:www-data "$DOCROOT"
# PHP/Apache lê pelo grupo, mas não pode escrever diretamente no wp-config.
chown root:www-data "$CONFIG_DESTINO"
find "$DOCROOT" -type d -exec chmod 0755 {} +
find "$DOCROOT" -type f ! -path "$CONFIG_DESTINO" -exec chmod 0644 {} +
chmod 0640 "$CONFIG_DESTINO"
chmod 0755 "$UPLOADS_DIR"

APACHE_CONF=/etc/apache2/conf-available/proxy-https.conf
cat > "$APACHE_CONF" <<'EOF'
<IfModule mod_setenvif.c>
    SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on
</IfModule>
EOF
a2enconf proxy-https >/dev/null
apache2ctl configtest >/dev/null
systemctl restart apache2
systemctl is-active --quiet apache2 || erro 'o serviço Apache não ficou ativo'

printf 'WordPress instalado/configurado em %s.\n' "$DOCROOT"
