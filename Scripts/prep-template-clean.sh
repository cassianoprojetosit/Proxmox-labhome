#!/usr/bin/env bash
set -euo pipefail

echo "Iniciando limpeza para template..."

# Remover SSH host keys
rm -f /etc/ssh/ssh_host_* || true

# Limpar machine-id
truncate -s 0 /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id || true

# Limpar logs
journalctl --rotate || true
journalctl --vacuum-time=1s || true
rm -f /var/log/wtmp /var/log/btmp || true
touch /var/log/wtmp /var/log/btmp || true
chmod 0664 /var/log/wtmp || true
chmod 0600 /var/log/btmp || true

# Limpar histórico
unset HISTFILE || true
history -c || true
rm -f /root/.bash_history || true

# Limpar cache apt
apt clean || true

# Limpar temporários
rm -rf /tmp/* /var/tmp/* || true

sync

echo "Limpeza concluída."
