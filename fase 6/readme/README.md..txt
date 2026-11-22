# Fase 6 - Snapshots, Backup e Restore

Projeto: final-equipeN

## O que é isso?
- Snapshot = foto rápida da máquina. Volta em 1 minuto.
- Backup = cópia completa salva em arquivo .tar.gz.
- Restore = voltar no tempo usando o snapshot ou o backup.

## Arquivos
- `script/01-snapshot.sh` - Tira foto do db, app e proxy
- `script/02-backup.sh` - Exporta os 3 para /opt/backups/fase-6
- `script/03-restore.sh` - Restaura um snapshot
- `script/04-limpeza.sh` - Limpa snapshots velhos

## Como testar na VM

1. Dar permissão:
```bash
chmod +x script/*.sh


./script/01-snapshot.sh

lxc info --project final-equipeN app

./script/02-backup.sh

./script/03-restore.sh app snap-20251122-1800