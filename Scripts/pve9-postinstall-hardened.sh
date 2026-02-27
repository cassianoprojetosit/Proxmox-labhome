#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ==========================================================
# Proxmox VE 9.x Post-Install Hardened (no hook)
# Focus: security, clean repos (deb822), optional nag removal
# ==========================================================

LOG_FILE="/var/log/pve-postinstall-hardened.log"

# ---------- Defaults (override by exporting env vars) ----------
ENABLE_NO_SUB_REPO="${ENABLE_NO_SUB_REPO:-yes}"         # yes/no -> enable pve-no-subscription
DISABLE_ENTERPRISE_REPOS="${DISABLE_ENTERPRISE_REPOS:-yes}" # yes/no -> disable enterprise repos (PVE/Ceph)
DISABLE_CEPH_REPOS="${DISABLE_CEPH_REPOS:-yes}"         # yes/no -> disable ceph repos (recommended for this lab)
DO_UPGRADE="${DO_UPGRADE:-yes}"                         # yes/no -> apt update + full-upgrade
REMOVE_SUBSCRIPTION_NAG="${REMOVE_SUBSCRIPTION_NAG:-yes}" # yes/no -> patch web UI nag (no hook)
HARDEN_SSH="${HARDEN_SSH:-no}"                          # yes/no -> disable root ssh + password auth (ONLY if keys are confirmed)
LIMIT_GUI_TO_LAN="${LIMIT_GUI_TO_LAN:-no}"              # yes/no -> restrict GUI/SSH to RFC1918 ranges (use carefully)
REBOOT_AFTER="${REBOOT_AFTER:-no}"                      # yes/no -> reboot at end

# ---------- Constants ----------
PVE_SUITE="trixie"
PVE_NO_SUB_URI="http://download.proxmox.com/debian/pve"
PVE_NO_SUB_COMP="pve-no-subscription"
PVE_KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"

# ---------- Helpers ----------
ts(){ date +%Y%m%d-%H%M%S; }

log() {
  local msg="$*"
  echo "[$(date -Is)] $msg" | tee -a "$LOG_FILE"
}

die(){ log "ERROR: $*"; exit 1; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root"; }

need_pve(){
  command -v pveversion >/dev/null 2>&1 || die "pveversion not found (not a Proxmox host?)"
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(ts)"
  log "Backup created: ${f}.bak.$(ts)"
}

# deb822 helper: ensure Enabled: yes/no
deb822_set_enabled() {
  local f="$1"
  local val="$2" # yes/no
  [[ -f "$f" ]] || return 0
  backup_file "$f"
  if grep -qE '^Enabled:' "$f"; then
    sed -i "s/^Enabled:.*/Enabled: ${val}/" "$f"
  else
    printf "\nEnabled: %s\n" "$val" >>"$f"
  fi
}

detect_pve_version() {
  # pveversion output: pve-manager/9.1.1/...
  local ver major
  ver="$(pveversion 2>/dev/null | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  major="$(cut -d. -f1 <<<"$ver")"
  echo "$major" "$ver"
}

disable_enterprise_repos() {
  log "Disabling enterprise repositories (PVE/Ceph) where present..."
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE 'enterprise\.proxmox\.com' "$f" || grep -qE '^Components:.*pve-enterprise' "$f"; then
      log "Enterprise reference found in $f -> Enabled: no"
      deb822_set_enabled "$f" "no"
    fi
  done
}

ensure_pve_no_subscription_repo() {
  local f="/etc/apt/sources.list.d/pve-no-subscription.sources"
  log "Ensuring pve-no-subscription repo (deb822): $f"
  backup_file "$f"
  cat >"$f" <<EOF
Types: deb
URIs: ${PVE_NO_SUB_URI}
Suites: ${PVE_SUITE}
Components: ${PVE_NO_SUB_COMP}
Signed-By: ${PVE_KEYRING}
EOF
  log "Wrote $f"
}

disable_ceph_repos() {
  log "Disabling Ceph repositories (recommended for this lab)..."
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE '/ceph-' "$f" || grep -qE 'Components:.*no-subscription' "$f" && grep -qiE 'ceph' "$f"; then
      log "Ceph reference found in $f -> Enabled: no"
      deb822_set_enabled "$f" "no"
    fi
  done
}

apt_update_upgrade() {
  log "Running apt-get update..."
  apt-get update 2>&1 | tee -a "$LOG_FILE"

  if [[ "$DO_UPGRADE" == "yes" ]]; then
    log "Running apt-get full-upgrade..."
    DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade 2>&1 | tee -a "$LOG_FILE"
  else
    log "Upgrade skipped (DO_UPGRADE=no)"
  fi
}

harden_ssh() {
  [[ "$HARDEN_SSH" == "yes" ]] || { log "SSH hardening skipped (HARDEN_SSH=no)"; return 0; }

  local sshd="/etc/ssh/sshd_config"
  backup_file "$sshd"

  log "Applying SSH hardening: PermitRootLogin no, PasswordAuthentication no"
  log "WARNING: Ensure key-based SSH access works before enabling this."

  sed -i \
    -e 's/^\s*#\?\s*PermitRootLogin\s\+.*/PermitRootLogin no/' \
    -e 's/^\s*#\?\s*PasswordAuthentication\s\+.*/PasswordAuthentication no/' \
    "$sshd" || true

  systemctl restart ssh
  log "SSH restarted"
}

limit_gui_firewall() {
  [[ "$LIMIT_GUI_TO_LAN" == "yes" ]] || { log "GUI firewall restriction skipped (LIMIT_GUI_TO_LAN=no)"; return 0; }

  log "Enabling Proxmox firewall and adding conservative rules for GUI/SSH (RFC1918 only)."
  log "WARNING: Verify you are connecting from LAN/VPN or you may lock yourself out."

  systemctl enable --now pve-firewall

  local nodefw="/etc/pve/nodes/$(hostname)/host.fw"
  if [[ -f "$nodefw" ]]; then
    backup_file "$nodefw"
    log "Existing $nodefw detected; backed up. Review and merge rules manually."
    return 0
  fi

  cat >"$nodefw" <<'EOF'
[OPTIONS]
enable: 1

[RULES]
# Allow Web GUI from private LAN ranges
IN ACCEPT -p tcp -dport 8006 -source 10.0.0.0/8
IN ACCEPT -p tcp -dport 8006 -source 172.16.0.0/12
IN ACCEPT -p tcp -dport 8006 -source 192.168.0.0/16

# Allow SSH from private LAN ranges (optional)
IN ACCEPT -p tcp -dport 22 -source 10.0.0.0/8
IN ACCEPT -p tcp -dport 22 -source 172.16.0.0/12
IN ACCEPT -p tcp -dport 22 -source 192.168.0.0/16
EOF

  pve-firewall restart
  log "Firewall rules created at $nodefw and firewall restarted."
}

remove_subscription_nag() {
  [[ "$REMOVE_SUBSCRIPTION_NAG" == "yes" ]] || { log "Nag removal skipped (REMOVE_SUBSCRIPTION_NAG=no)"; return 0; }

  local webjs="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  [[ -f "$webjs" ]] || { log "Nag patch skipped: $webjs not found"; return 0; }

  backup_file "$webjs"

  if grep -q "PVE_NO_SUB_NAG_PATCH_APPLIED" "$webjs"; then
    log "Nag patch already applied (marker found)."
    return 0
  fi

  log "Applying 'best effort' nag patch (no hook)."
  local tmp
  tmp="$(mktemp)"

  perl -0777 -pe '
    my $count = 0;

    # Replace a common guarded block that shows a subscription dialog
    s{
      if\s*\([^)]*\)\s*\{\s*
      ([^{}]*?Ext\.Msg\.show\s*\(\s*\{[^}]*getNoSubKeyHtml[^}]*\}\s*\)\s*;[^}]*)
      \}
    }{
      $count++;
      "if (false) { $1 }\n"
    }gsex;

    $_ .= "\n/* PVE_NO_SUB_NAG_PATCH_APPLIED */\n" if $count > 0;
    $_
  ' "$webjs" > "$tmp"

  if grep -q "PVE_NO_SUB_NAG_PATCH_APPLIED" "$tmp"; then
    cp -a "$tmp" "$webjs"
    rm -f "$tmp"
    systemctl restart pveproxy
    log "Nag patch applied and pveproxy restarted."
    log "IMPORTANT: Clear browser cache / hard reload (Ctrl+Shift+R) or use Incognito."
  else
    rm -f "$tmp"
    log "Nag patch NOT applied (pattern not found). Your build may differ."
    log "If needed, we can generate a targeted patch from a small snippet of proxmoxlib.js."
  fi
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" || true

  need_root
  need_pve

  local major ver
  read -r major ver < <(detect_pve_version)
  log "Detected Proxmox VE version: $ver (major=$major)"
  [[ "$major" == "9" ]] || die "This script targets Proxmox VE 9.x. Detected: $ver"

  log "Settings: ENABLE_NO_SUB_REPO=$ENABLE_NO_SUB_REPO DISABLE_ENTERPRISE_REPOS=$DISABLE_ENTERPRISE_REPOS DISABLE_CEPH_REPOS=$DISABLE_CEPH_REPOS DO_UPGRADE=$DO_UPGRADE REMOVE_SUBSCRIPTION_NAG=$REMOVE_SUBSCRIPTION_NAG HARDEN_SSH=$HARDEN_SSH LIMIT_GUI_TO_LAN=$LIMIT_GUI_TO_LAN REBOOT_AFTER=$REBOOT_AFTER"

  [[ -f "$PVE_KEYRING" ]] || log "WARNING: Proxmox keyring not found at $PVE_KEYRING. Verify APT signing if issues occur."

  if [[ "$DISABLE_ENTERPRISE_REPOS" == "yes" ]]; then
    disable_enterprise_repos
  else
    log "Enterprise repos not modified (DISABLE_ENTERPRISE_REPOS=no)"
  fi

  if [[ "$ENABLE_NO_SUB_REPO" == "yes" ]]; then
    ensure_pve_no_subscription_repo
  else
    log "No-subscription repo not created/enabled (ENABLE_NO_SUB_REPO=no)"
  fi

  if [[ "$DISABLE_CEPH_REPOS" == "yes" ]]; then
    disable_ceph_repos
  else
    log "Ceph repos not modified (DISABLE_CEPH_REPOS=no)"
  fi

  apt_update_upgrade
  harden_ssh
  limit_gui_firewall
  remove_subscription_nag

  log "Completed. Log file: $LOG_FILE"
  log "Recommended: reboot when convenient."

  if [[ "$REBOOT_AFTER" == "yes" ]]; then
    log "Rebooting now..."
    reboot
  else
    log "To reboot later: reboot"
  fi
}

main "$@"
