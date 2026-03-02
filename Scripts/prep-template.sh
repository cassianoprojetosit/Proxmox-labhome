#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Proxmox Template Prep - Ubuntu/Debian
# - Limpa identidades (machine-id, ssh host keys, logs)
# - (Opcional) instala serviço de first-boot para clones
# =========================================================

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root: sudo $0"
  exit 1
fi

echo "==============================================="
echo " PREP TEMPLATE - Limpeza antes de virar template"
echo "==============================================="

read -rp "Instalar serviço de FIRST BOOT (recomendado) no template? (s/N): " INSTALL_FIRSTBOOT
INSTALL_FIRSTBOOT="${INSTALL_FIRSTBOOT,,}"

echo
echo "[1/6] Limpando machine-id..."
: > /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id || true

echo
echo "[2/6] Removendo SSH host keys..."
rm -f /etc/ssh/ssh_host_* || true

echo
echo "[3/6] Limpando logs do journal..."
journalctl --rotate || true
journalctl --vacuum-time=1s || true
rm -f /var/log/wtmp /var/log/btmp || true
touch /var/log/wtmp /var/log/btmp || true
chmod 0664 /var/log/wtmp || true
chmod 0600 /var/log/btmp || true

echo
echo "[4/6] Limpando regras persistentes (quando existirem)..."
rm -f /etc/udev/rules.d/70-persistent-net.rules || true
rm -f /var/lib/systemd/random-seed || true

echo
echo "[5/6] (Opcional) Desligando cloud-init se você NÃO usa..."
read -rp "Você usa cloud-init? (S/n): " USE_CLOUDINIT
USE_CLOUDINIT="${USE_CLOUDINIT,,}"
if [[ "$USE_CLOUDINIT" == "n" ]]; then
  echo "-> Você disse que NÃO usa cloud-init. Não vou mexer em pacotes."
  echo "   (Se quiser remover: apt purge cloud-init -y)"
else
  echo "-> Cloud-init mantido."
fi

if [[ "$INSTALL_FIRSTBOOT" == "s" || "$INSTALL_FIRSTBOOT" == "sim" || "$INSTALL_FIRSTBOOT" == "y" || "$INSTALL_FIRSTBOOT" == "yes" ]]; then
  echo
  echo "[6/6] Instalando serviço first-boot (vai rodar no clone 1x)..."

  install -d /usr/local/sbin
  cat >/usr/local/sbin/firstboot-clone-setup.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/firstboot-clone-setup.done"

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root: sudo $0"
  exit 1
fi

if [[ -f "$MARKER" ]]; then
  echo "Firstboot já executado. Nada a fazer."
  exit 0
fi

echo "==============================================="
echo " FIRST BOOT - Configuração do CLONE (1x)"
echo "==============================================="

# 1) Garantir machine-id novo
echo "[1/6] Gerando machine-id..."
rm -f /etc/machine-id /var/lib/dbus/machine-id || true
systemd-machine-id-setup || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id || true

# 2) Gerar SSH host keys novas
echo "[2/6] Gerando SSH host keys..."
rm -f /etc/ssh/ssh_host_* || true
# Debian/Ubuntu: reconfigure do openssh-server costuma recriar
if command -v dpkg-reconfigure >/dev/null 2>&1; then
  dpkg-reconfigure openssh-server >/dev/null 2>&1 || true
fi
# fallback: ssh-keygen direto (garante)
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -A || true
fi

# 3) Hostname
echo "[3/6] Ajustando hostname..."
CURRENT_HOST="$(hostname)"
read -rp "Hostname atual é '$CURRENT_HOST'. Novo hostname (ENTER mantém): " NEW_HOST
NEW_HOST="${NEW_HOST:-$CURRENT_HOST}"
hostnamectl set-hostname "$NEW_HOST"

# Ajustar /etc/hosts (mantém 127.0.1.1 padrão do Debian/Ubuntu)
if grep -qE '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOST/" /etc/hosts
else
  echo -e "127.0.1.1\t$NEW_HOST" >> /etc/hosts
fi

# 4) Rede (netplan) - opcional IP fixo
echo "[4/6] Configuração de rede (opcional)..."
read -rp "Deseja configurar IP FIXO via netplan agora? (s/N): " SET_STATIC
SET_STATIC="${SET_STATIC,,}"

if [[ "$SET_STATIC" == "s" || "$SET_STATIC" == "sim" || "$SET_STATIC" == "y" || "$SET_STATIC" == "yes" ]]; then
  # detectar interface principal (primeira UP não-lo)
  IFACE="$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')"
  echo "Interface detectada: $IFACE"

  read -rp "IP (ex: 10.10.10.10): " IP_ADDR
  read -rp "CIDR (ex: 24): " CIDR
  read -rp "Gateway (ex: 10.10.10.1): " GW
  read -rp "DNS (ex: 1.1.1.1,8.8.8.8): " DNS

  NETPLAN_FILE="/etc/netplan/01-firstboot-static.yaml"
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

  echo "-> Arquivo criado: $NETPLAN_FILE"
  echo "-> Aplicando netplan..."
  netplan generate
  netplan apply
else
  echo "-> IP fixo não configurado."
fi

# 5) Garantir ssh ativo
echo "[5/6] Reiniciando SSH..."
systemctl enable ssh || true
systemctl restart ssh || systemctl restart sshd || true

# 6) Marcar como executado e desabilitar service
echo "[6/6] Finalizando..."
touch "$MARKER"
systemctl disable firstboot-clone-setup.service >/dev/null 2>&1 || true

echo "OK. First boot concluído. Recomendado reiniciar a VM."
EOF

  chmod +x /usr/local/sbin/firstboot-clone-setup.sh

  cat >/etc/systemd/system/firstboot-clone-setup.service <<'EOF'
[Unit]
Description=First boot setup for Proxmox clones (hostname, ssh keys, optional netplan)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot-clone-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable firstboot-clone-setup.service
  echo "-> Serviço habilitado: firstboot-clone-setup.service"
else
  echo
  echo "[6/6] Serviço first-boot não instalado (você pode rodar manualmente no clone depois)."
fi

echo
echo "==============================================="
echo "Template preparado."
echo "Próximo passo no Proxmox: qm template <VMID>"
echo "==============================================="
