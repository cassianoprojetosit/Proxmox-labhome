# Technical Documentation -- Template Preparation (v1.0 Official)

Updated: 2026-03-03

---

## Pre-Template Cleanup Script

File:
/usr/local/sbin/prep-template-clean.sh

#!/usr/bin/env bash
set -euo pipefail

echo "Starting template cleanup..."

# Remove SSH host keys
rm -f /etc/ssh/ssh_host_* || true

# Clean machine-id
truncate -s 0 /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id || true

# Clean logs
journalctl --rotate || true
journalctl --vacuum-time=1s || true
rm -f /var/log/wtmp /var/log/btmp || true
touch /var/log/wtmp /var/log/btmp || true
chmod 0664 /var/log/wtmp || true
chmod 0600 /var/log/btmp || true

# Clean history
unset HISTFILE || true
history -c || true
rm -f /root/.bash_history || true

# Clean apt cache
apt clean || true

# Clean temporary files
rm -rf /tmp/* /var/tmp/* || true

sync

echo "Cleanup completed."

---

## Template Finalization

Inside VM:

sudo /usr/local/sbin/prep-template-clean.sh
sudo shutdown -h now

On Proxmox host:

qm template 100

---

## Result

- Minimal Ubuntu template
- SSH keys auto-regenerated on clone
- Machine ID reset
- Logs cleared
- Clean baseline ready for production lab
