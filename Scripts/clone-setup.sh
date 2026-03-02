#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/clone-setup.done"

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root: sudo $0"
  exit 1
fi

if [[ -f "$MARKER" ]]; then
  echo "Clone setup já executado. (Apague $MARKER se quiser rodar de novo.)"
  exit 0
fi

echo "==============================================="
echo " CLONE SETUP - Pós-clone (hostname, ssh, rede)"
echo "==============================================="

echo "[1/5] Gerando machine-id..."
rm -f /etc/machine-id /var/lib/dbus/machine-id || true
systemd-machine-id-setup || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id || true

echo "[2/5] Gerando SSH host keys..."
rm -f /etc/ssh/ssh_host_* || true
if command -v dpkg-reconfigure >/dev/null 2>&1; then
  dpkg-reconfigure openssh-server >/dev/null 2>&1 || true
fi
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -A || true
fi

echo "[3/5] Hostname..."
CURRENT_HOST="$(hostname)"
read -rp "Hostname atual '$CURRENT_HOST'. Novo hostname (ENTER mantém): " NEW_HOST
NEW_HOST="${NEW_HOST:-$CURRENT_HOST}"
hostnamectl set-hostname "$NEW_HOST"

if grep -qE '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOST/" /etc/hosts
else
  echo -e "127.0.1.1\t$NEW_HOST" >> /etc/hosts
fi

echo "[4/5] Rede (netplan) opcional..."
read -rp "Configurar IP FIXO agora? (s/N): " SET_STATIC
SET_STATIC="${SET_STATIC,,}"

if [[ "$SET_STATIC" == "s" || "$SET_STATIC" == "sim" || "$SET_STATIC" == "y" || "$SET_STATIC" == "yes" ]]; then
  IFACE="$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')"
  echo "Interface detectada: $IFACE"

  read -rp "IP (ex: 10.10.10.10): " IP_ADDR
  read -rp "CIDR (ex: 24): " CIDR
  read -rp "Gateway (ex: 10.10.10.1): " GW
  read -rp "DNS (ex: 1.1.1.1,8.8.8.8): " DNS

  NETPLAN_FILE="/etc/netplan/01-clone-static.yaml"
  cat >"$NETPLAN_FILE" <<EON
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses:
        - $IP_ADDR/$CIDR
      routes:
        - to: default
          via: $GW
      nameservers:
        addresses: [${DNS}]
EON

  netplan generate
  netplan apply
else
  echo "-> IP fixo não configurado."
fi

echo "[5/5] Reiniciando SSH..."
systemctl enable ssh || true
systemctl restart ssh || systemctl restart sshd || true

touch "$MARKER"
echo "OK. Recomendado reiniciar a VM."
