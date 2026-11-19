# Fase 5 — Acesso, permissões e HTTPS

## Objetivo

Implementar mecanismos de controle de acesso à infraestrutura LXD e disponibilizar o WordPress por meio de uma conexão HTTPS.

## Controle de acesso

- Administrador: acesso global à infraestrutura LXD.
- Operador: acesso restrito ao projeto da equipe.
- API HTTPS do LXD: porta 8443.

## Segurança do serviço

- Autoridade certificadora própria.
- Certificado digital assinado pela CA da equipe.
- Protocolos TLS 1.2 e TLS 1.3.
- Redirecionamento de HTTP para HTTPS.
- Publicação do WordPress na porta 8444.

## Execução

Executar na máquina virtual, a partir da raiz do repositório:

`bash scripts/fase5-acesso.sh`

Registrar os clientes administrador e operador utilizando seus respectivos tokens.

`bash scripts/fase5-tls.sh`

Importar o certificado público da CA no computador utilizado para os testes.

## Evidências necessárias

- Lista dos certificados de acesso do LXD.
- Administrador acessando diferentes projetos.
- Operador acessando o projeto autorizado.
- Operador recebendo erro ao acessar o projeto default.
- Validação da configuração do Nginx.
- Resultado do teste HTTPS pelo curl.
- WordPress acessível pelo navegador sem aviso de certificado.

## Segurança das informações

As chaves privadas, senhas e tokens não devem ser publicados no GitHub.

## Status

Arquivos e scripts preparados. Execução e validação na máquina virtual pendentes.