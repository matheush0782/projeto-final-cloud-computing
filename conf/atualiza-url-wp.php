<?php
/**
 * Atualiza APENAS WP_HOME e WP_SITEURL sem depender da formatação dos espaços.
 * Uso na instância: WP_SITE_URL=https://127.0.0.1:8444 php /root/atualiza-url-wp.php
 * Para testes, pode receber o caminho do wp-config.php como primeiro argumento.
 */
declare(strict_types=1);

$url = getenv('WP_SITE_URL');
if (!is_string($url) || !preg_match('~^https://[0-9.]+:[0-9]{1,5}$~D', $url)) {
    fwrite(STDERR, "WP_SITE_URL deve ser uma URL HTTPS com IP e porta.\n");
    exit(1);
}

$arquivo = $argv[1] ?? '/var/www/html/wp-config.php';
if (!is_file($arquivo) || !is_readable($arquivo) || is_link($arquivo)) {
    fwrite(STDERR, "wp-config.php nao encontrado, nao legivel ou link simbolico.\n");
    exit(1);
}
$conteudo = file_get_contents($arquivo);
if ($conteudo === false) {
    fwrite(STDERR, "Nao foi possivel ler wp-config.php.\n");
    exit(1);
}
foreach (['WP_HOME', 'WP_SITEURL'] as $nome) {
    $padrao = '/^[ \t]*define\s*\(\s*([\'\"])' . preg_quote($nome, '/') . '\\1\s*,[^\r\n]*\)\s*;[ \t]*$/m';
    $linha = 'define( ' . var_export($nome, true) . ', ' . var_export($url, true) . ' );';
    $novo = preg_replace_callback($padrao, static fn() => $linha, $conteudo, -1, $quantidade);
    if ($novo === null || $quantidade !== 1) {
        fwrite(STDERR, "Esperada exatamente uma definicao de {$nome}; nenhuma alteracao salva.\n");
        exit(1);
    }
    $conteudo = $novo;
}
$stat = stat($arquivo);
if ($stat === false) {
    fwrite(STDERR, "Nao foi possivel consultar permissoes.\n");
    exit(1);
}
$temporario = tempnam(dirname($arquivo), '.wp-config-fase5-');
if ($temporario === false) {
    fwrite(STDERR, "Nao foi possivel criar arquivo temporario.\n");
    exit(1);
}
try {
    if (file_put_contents($temporario, $conteudo, LOCK_EX) === false ||
        !chown($temporario, $stat['uid']) ||
        !chgrp($temporario, $stat['gid']) ||
        !chmod($temporario, $stat['mode'] & 0777) ||
        !rename($temporario, $arquivo)) {
        throw new RuntimeException('Falha na escrita segura do wp-config.php.');
    }
} catch (Throwable $e) {
    @unlink($temporario);
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}
echo "WP_HOME e WP_SITEURL atualizados com sucesso.\n";
