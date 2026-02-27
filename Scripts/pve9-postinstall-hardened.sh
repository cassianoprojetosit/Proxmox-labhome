#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ==========================================================
# Proxmox VE 9.x Post-Install Hardened (no hook)
# Focus: security, clean repos, optional nag removal
# Works with deb822 (*.sources) on Debian Trixie (PVE 9.x)
# ==========================================================

LOG_FILE="/var/log/pve-postinstall-hardened.log"

# ---------- User-tunable defaults ----------
# Set these before running, or export env vars with same names.
: "${ENABLE_NO_SUB_REPO:=yes}"     # yes/no  -> enable pve-no-subscription
: "${DISABLE_ENTERPRISE_REPOS:=yes}" # yes/no -> disable enterprise repos (PVE/Ceph)
: "${DISABLE_CEPH_REPOS:=yes}"     # yes/no  -> disable ceph repos (you said you won't use ceph now)
: "${DO_UPGRADE:=yes}"             # yes/no  -> apt update + full-upgrade
: "${REMOVE_SUBSCRIPTION_NAG:=yes}"# yes/no  -> patch web UI nag (no hook)
: "${HARDEN_SSH:=no}"              # yes/no  -> disable root ssh + password auth (ONLY if keys are confirmed)
: "${LIMIT_GUI_TO_LAN:=no}"        # yes/no  -> basic firewall: allow 8006 only from RFC1918 LANs (conservative)
: "${REBOOT_AFTER:=no}"            # yes/no  -> reboot at end

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

detect_pve_major_minor() {
  # pveversion output: pve-manager/9.1.1/...
  local ver major minor
  ver="$(pveversion 2>/dev/null | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  major="$(cut -d. -f1 <<<"$ver")"
  minor="$(cut -d. -f2 <<<"$ver")"
  echo "$major" "$minor" "$ver"
}

disable_enterprise_repos() {
  log "Disabling enterprise repositories (PVE/Ceph) where present..."

  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE 'enterprise\.proxmox\.com' "$f"; then
      log "Enterprise reference found in $f -> setting Enabled: no"
      deb822_set_enabled "$f" "no"
    fi
    # Also catch explicit Components: pve-enterprise / enterprise
    if grep -qE '^Components:.*pve-enterprise' "$f"; then
      log "pve-enterprise component found in $f -> setting Enabled: no"
      deb822_set_enabled "$f" "no"
    fi
  done
}

ensure_pve_no_subscription_repo() {
  local f="/etc/apt/sources.list.d/pve-no-subscription.sources"
  log "Ensuring pve-no-subscription repo: $f"
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
  log "Disabling Ceph repositories (opt-out for this lab)..."
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE '/ceph-' "$f"; then
      log "Ceph repo found in $f -> setting Enabled: no"
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

  log "Applying conservative SSH hardening: PermitRootLogin no, PasswordAuthentication no"
  # NOTE: only safe if key-based SSH access is confirmed
  sed -i \
    -e 's/^\s*#\?\s*PermitRootLogin\s\+.*/PermitRootLogin no/' \
    -e 's/^\s*#\?\s*PasswordAuthentication\s\+.*/PasswordAuthentication no/' \
    "$sshd" || true

  systemctl restart ssh
  log "SSH restarted"
}

limit_gui_firewall() {
  [[ "$LIMIT_GUI_TO_LAN" == "yes" ]] || { log "GUI firewall restriction skipped (LIMIT_GUI_TO_LAN=no)"; return 0; }

  # Conservative approach using Proxmox firewall (pve-firewall).
  # This can lock you out if you're not on LAN. Use with caution.
  log "Enabling Proxmox firewall and restricting GUI (8006) to RFC1918 LAN ranges (conservative)."

  # Enable firewall at datacenter/node level (safe defaults but verify in GUI later)
  pve-firewall stop || true
  sed -i.bak."$(ts)" 's/^ENABLE:.*/ENABLE: 1/' /etc/pve/firewall/cluster.fw 2>/dev/null || true
  mkdir -p /etc/pve/firewall 2>/dev/null || true

  # Node firewall file
  local nodefw="/etc/pve/nodes/$(hostname)/host.fw"
  if [[ ! -f "$nodefw" ]]; then
    cat >"$nodefw" <<'EOF'
[OPTIONS]
enable: 1

[RULES]
# Allow GUI from private LAN ranges only
IN ACCEPT -p tcp -dport 8006 -source 10.0.0.0/8
IN ACCEPT -p tcp -dport 8006 -source 172.16.0.0/12
IN ACCEPT -p tcp -dport 8006 -source 192.168.0.0/16

# Allow SSH from private LAN ranges only (optional; comment out if needed)
IN ACCEPT -p tcp -dport 22 -source 10.0.0.0/8
IN ACCEPT -p tcp -dport 22 -source 172.16.0.0/12
IN ACCEPT -p tcp -dport 22 -source 192.168.0.0/16

# Drop everything else to GUI/SSH is not automatic here; Proxmox firewall is stateful and your existing rules matter.
EOF
  else
    backup_file "$nodefw"
    log "Firewall file already exists at $nodefw (kept + backed up). Review manually."
  fi

  systemctl enable --now pve-firewall
  pve-firewall start
  log "pve-firewall enabled and started. Verify access before disconnecting!"
}

remove_subscription_nag() {
  [[ "$REMOVE_SUBSCRIPTION_NAG" == "yes" ]] || { log "Nag removal skipped (REMOVE_SUBSCRIPTION_NAG=no)"; return 0; }

  local webjs="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  [[ -f "$webjs" ]] || { log "Nag patch skipped: $webjs not found"; return 0; }

  backup_file "$webjs"

  # We attempt a minimal, reversible patch:
  # 1) Mark file with a token so we don't patch repeatedly
  # 2) Try to neutralize the subscription popup condition around getNoSubKeyHtml/Ext.Msg.show
  if grep -q "PVE_NO_SUB_NAG_PATCH_APPLIED" "$webjs"; then
    log "Nag patch already applied (marker found)."
    return 0
  fi

  log "Applying 'best effort' nag patch to $webjs (no hook)."

  # Approach:
  # - Find the first occurrence of getNoSubKeyHtml usage in a block that shows Ext.Msg.show.
  # - Replace the IF condition guarding that popup with 'if (false) {'.
  # This is intentionally conservative; if pattern not found, we do nothing.

  # Create a temp patched file with perl for safer multiline edits
  local tmp
  tmp="$(mktemp)"

  perl -0777 -pe '
    if (!/getNoSubKeyHtml/) { print; exit; }

    # Try patching a common pattern:
    # if (something) { Ext.Msg.show(... getNoSubKeyHtml ...); }
    # Replace only the "if (...)" that immediately precedes an Ext.Msg.show containing getNoSubKeyHtml
    my $count = 0;

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
    log "Nag patch applied and pveproxy restarted. (Clear browser cache / hard reload)."
  else
    rm -f "$tmp"
    log "Nag patch NOT applied (pattern not found). Your build may differ."
    log "If you want, I can generate a targeted patch based on a small snippet from your proxmoxlib.js."
  fi
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" || true

  need_root
  need_pve

  local major minor ver
  read -r major minor ver < <(detect_pve_major_minor)
  log "Detected Proxmox VE version: $ver (major=$major minor=$minor)"
  [[ "$major" == "9" ]] || die "This script is intended for Proxmox VE 9.x. Detected: $ver"

  # Keyring sanity check
  [[ -f "$PVE_KEYRING" ]] || log "WARNING: Proxmox keyring not found at $PVE_KEYRING (APT may still work, but verify)."

  log "Settings: ENABLE_NO_SUB_REPO=$ENABLE_NO_SUB_REPO DISABLE_ENTERPRISE_REPOS=$DISABLE_ENTERPRISE_REPOS DISABLE_CEPH_REPOS=$DISABLE_CEPH_REPOS DO_UPGRADE=$DO_UPGRADE REMOVE_SUBSCRIPTION_NAG=$REMOVE_SUBSCRIPTION_NAG HARDEN_SSH=$HARDEN_SSH LIMIT_GUI_TO_LAN=$LIMIT_GUI_TO_LAN REBOOT_AFTER=$REBOOT_AFTER"

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
  log "IMPORTANT: Clear browser cache / hard reload (Ctrl+Shift+R) after UI changes."

  if [[ "$REBOOT_AFTER" == "yes" ]]; then
    log "Rebooting now..."
    reboot
  else
    log "Reboot recommended: run 'reboot' when convenient."
  fi
}

main "$@"
