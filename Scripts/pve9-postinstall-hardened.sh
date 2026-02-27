#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ==========================================================
# Proxmox VE 9.x Post-Install Hardened (no hook)
# Focus: security, clean repos (deb822), optional nag removal
# Adds: per-step status + end summary
# ==========================================================

LOG_FILE="/var/log/pve-postinstall-hardened.log"

# ---------- Defaults (override by exporting env vars) ----------
ENABLE_NO_SUB_REPO="${ENABLE_NO_SUB_REPO:-yes}"             # yes/no -> enable pve-no-subscription
DISABLE_ENTERPRISE_REPOS="${DISABLE_ENTERPRISE_REPOS:-yes}" # yes/no -> disable enterprise repos (PVE/Ceph)
DISABLE_CEPH_REPOS="${DISABLE_CEPH_REPOS:-yes}"             # yes/no -> disable ceph repos (recommended for this lab)
DO_UPGRADE="${DO_UPGRADE:-yes}"                             # yes/no -> apt update + full-upgrade
REMOVE_SUBSCRIPTION_NAG="${REMOVE_SUBSCRIPTION_NAG:-yes}"    # yes/no -> patch web UI nag (no hook)
HARDEN_SSH="${HARDEN_SSH:-no}"                              # yes/no -> disable root ssh + password auth (ONLY if keys are confirmed)
LIMIT_GUI_TO_LAN="${LIMIT_GUI_TO_LAN:-no}"                  # yes/no -> restrict GUI/SSH to RFC1918 ranges (use carefully)
REBOOT_AFTER="${REBOOT_AFTER:-no}"                          # yes/no -> reboot at end

# ---------- Constants ----------
PVE_SUITE="trixie"
PVE_NO_SUB_URI="http://download.proxmox.com/debian/pve"
PVE_NO_SUB_COMP="pve-no-subscription"
PVE_KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"

# ---------- Result bookkeeping ----------
declare -A STEP_OK
declare -A STEP_MSG

mark_ok()   { STEP_OK["$1"]="OK";   STEP_MSG["$1"]="${2:-}"; }
mark_warn() { STEP_OK["$1"]="WARN"; STEP_MSG["$1"]="${2:-}"; }
mark_fail() { STEP_OK["$1"]="FAIL"; STEP_MSG["$1"]="${2:-}"; }

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

safe_run_step() {
  # Run a function as a "step" without killing the whole script.
  # Usage: safe_run_step "STEP_NAME" function_name
  local step="$1"
  local fn="$2"

  set +e
  "$fn"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    [[ -z "${STEP_OK[$step]:-}" ]] && mark_ok "$step"
  else
    # If function didn't mark itself, mark fail
    [[ -z "${STEP_OK[$step]:-}" ]] && mark_fail "$step" "Exit code: $rc"
  fi
  return 0
}

# ---------- Steps ----------
step_disable_enterprise_repos() {
  local step="disable_enterprise_repos"
  if [[ "$DISABLE_ENTERPRISE_REPOS" != "yes" ]]; then
    mark_warn "$step" "Skipped (DISABLE_ENTERPRISE_REPOS=no)"
    return 0
  fi

  log "Disabling enterprise repositories (PVE/Ceph) where present..."
  local touched=0
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE 'enterprise\.proxmox\.com' "$f" || grep -qE '^Components:.*pve-enterprise' "$f"; then
      log "Enterprise reference found in $f -> Enabled: no"
      deb822_set_enabled "$f" "no"
      touched=$((touched+1))
    fi
  done

  if [[ $touched -gt 0 ]]; then
    mark_ok "$step" "Disabled enterprise entries in ${touched} file(s)"
  else
    mark_ok "$step" "No enterprise entries found (nothing to change)"
  fi
  return 0
}

step_enable_no_subscription_repo() {
  local step="enable_no_subscription_repo"
  if [[ "$ENABLE_NO_SUB_REPO" != "yes" ]]; then
    mark_warn "$step" "Skipped (ENABLE_NO_SUB_REPO=no)"
    return 0
  fi

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
  mark_ok "$step" "Created/updated $f"
  return 0
}

step_disable_ceph_repos() {
  local step="disable_ceph_repos"
  if [[ "$DISABLE_CEPH_REPOS" != "yes" ]]; then
    mark_warn "$step" "Skipped (DISABLE_CEPH_REPOS=no)"
    return 0
  fi

  log "Disabling Ceph repositories (recommended for this lab)..."
  local touched=0
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE '/ceph-' "$f" || (grep -qiE 'ceph' "$f" && grep -qE '^URIs:.*download\.proxmox\.com/.*/ceph' "$f"); then
      log "Ceph reference found in $f -> Enabled: no"
      deb822_set_enabled "$f" "no"
      touched=$((touched+1))
    fi
  done

  if [[ $touched -gt 0 ]]; then
    mark_ok "$step" "Disabled Ceph entries in ${touched} file(s)"
  else
    mark_ok "$step" "No Ceph entries found (nothing to change)"
  fi
  return 0
}

step_apt_update_upgrade() {
  local step="apt_update_upgrade"
  log "Running apt-get update..."
  if ! apt-get update 2>&1 | tee -a "$LOG_FILE"; then
    mark_fail "$step" "apt-get update failed (check log: $LOG_FILE)"
    return 1
  fi

  if [[ "$DO_UPGRADE" == "yes" ]]; then
    log "Running apt-get full-upgrade..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade 2>&1 | tee -a "$LOG_FILE"; then
      mark_fail "$step" "apt-get full-upgrade failed (check log: $LOG_FILE)"
      return 1
    fi
    mark_ok "$step" "apt update + full-upgrade completed"
  else
    mark_warn "$step" "Upgrade skipped (DO_UPGRADE=no)"
  fi
  return 0
}

step_harden_ssh() {
  local step="harden_ssh"
  if [[ "$HARDEN_SSH" != "yes" ]]; then
    mark_warn "$step" "Skipped (HARDEN_SSH=no)"
    return 0
  fi

  local sshd="/etc/ssh/sshd_config"
  backup_file "$sshd"
  log "Applying SSH hardening: PermitRootLogin no, PasswordAuthentication no"
  log "WARNING: ensure key-based SSH access works before enabling this."

  # Conservative replacements (won't error if directives absent)
  sed -i \
    -e 's/^\s*#\?\s*PermitRootLogin\s\+.*/PermitRootLogin no/' \
    -e 's/^\s*#\?\s*PasswordAuthentication\s\+.*/PasswordAuthentication no/' \
    "$sshd" || true

  if systemctl restart ssh; then
    mark_ok "$step" "SSH hardened and service restarted"
    return 0
  else
    mark_fail "$step" "Failed to restart ssh after changes"
    return 1
  fi
}

step_limit_gui_firewall() {
  local step="limit_gui_firewall"
  if [[ "$LIMIT_GUI_TO_LAN" != "yes" ]]; then
    mark_warn "$step" "Skipped (LIMIT_GUI_TO_LAN=no)"
    return 0
  fi

  log "Enabling Proxmox firewall and adding conservative RFC1918 rules for GUI/SSH."
  log "WARNING: you can lock yourself out if not on LAN/VPN."

  if ! systemctl enable --now pve-firewall; then
    mark_fail "$step" "Failed to enable pve-firewall"
    return 1
  fi

  local nodefw="/etc/pve/nodes/$(hostname)/host.fw"
  if [[ -f "$nodefw" ]]; then
    backup_file "$nodefw"
    mark_warn "$step" "host.fw already exists; backed up. Merge rules manually."
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

  if pve-firewall restart; then
    mark_ok "$step" "Firewall rules applied (host.fw created) and firewall restarted"
    return 0
  else
    mark_fail "$step" "Firewall restart failed"
    return 1
  fi
}

step_remove_subscription_nag() {
  local step="remove_subscription_nag"
  if [[ "$REMOVE_SUBSCRIPTION_NAG" != "yes" ]]; then
    mark_warn "$step" "Skipped (REMOVE_SUBSCRIPTION_NAG=no)"
    return 0
  fi

  local webjs="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  if [[ ! -f "$webjs" ]]; then
    mark_fail "$step" "File not found: $webjs"
    return 1
  fi

  backup_file "$webjs"

  if grep -q "PVE_NO_SUB_NAG_PATCH_APPLIED" "$webjs"; then
    mark_ok "$step" "Already patched (marker found)."
    return 0
  fi

  log "Applying 'best effort' nag patch (no hook)."
  local tmp
  tmp="$(mktemp)"

  # IMPORTANT: no stray '[' in regex (fixed).
  # We try to locate an if(...) { Ext.Msg.show({...getNoSubKeyHtml...}); } and replace condition with if(false).
  set +e
  perl -0777 -pe '
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
  local prc=$?
  set -e

  if [[ $prc -ne 0 ]]; then
    rm -f "$tmp"
    mark_fail "$step" "Perl patch failed (exit $prc). No changes applied."
    return 1
  fi

  if grep -q "PVE_NO_SUB_NAG_PATCH_APPLIED" "$tmp"; then
    cp -a "$tmp" "$webjs"
    rm -f "$tmp"
    if systemctl restart pveproxy; then
      mark_ok "$step" "Patched proxmoxlib.js + restarted pveproxy. Clear browser cache / hard reload."
      return 0
    else
      mark_warn "$step" "Patched proxmoxlib.js but failed to restart pveproxy (restart manually)."
      return 0
    fi
  else
    rm -f "$tmp"
    mark_warn "$step" "Pattern not found (your build differs). No UI change made."
    return 0
  fi
}

print_summary() {
  echo
  log "================= SUMMARY ================="
  printf "\n%-28s %-6s %s\n" "STEP" "STATUS" "DETAILS" | tee -a "$LOG_FILE"
  printf "%-28s %-6s %s\n" "----" "------" "-------" | tee -a "$LOG_FILE"

  local steps=(
    "disable_enterprise_repos"
    "enable_no_subscription_repo"
    "disable_ceph_repos"
    "apt_update_upgrade"
    "harden_ssh"
    "limit_gui_firewall"
    "remove_subscription_nag"
  )

  for s in "${steps[@]}"; do
    local st="${STEP_OK[$s]:-SKIP}"
    local msg="${STEP_MSG[$s]:-}"
    printf "%-28s %-6s %s\n" "$s" "$st" "$msg" | tee -a "$LOG_FILE"
  done

  echo | tee -a "$LOG_FILE"
  log "Log file: $LOG_FILE"
  log "NOTE: If UI was patched, clear browser cache or use Incognito + hard reload (Ctrl+Shift+R)."
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" || true

  need_root
  need_pve

  local major ver
  read -r major ver < <(detect_pve_version)
  log "Detected Proxmox VE version: $ver (major=$major)"
  if [[ "$major" != "9" ]]; then
    die "This script targets Proxmox VE 9.x. Detected: $ver"
  fi

  log "Settings: ENABLE_NO_SUB_REPO=$ENABLE_NO_SUB_REPO DISABLE_ENTERPRISE_REPOS=$DISABLE_ENTERPRISE_REPOS DISABLE_CEPH_REPOS=$DISABLE_CEPH_REPOS DO_UPGRADE=$DO_UPGRADE REMOVE_SUBSCRIPTION_NAG=$REMOVE_SUBSCRIPTION_NAG HARDEN_SSH=$HARDEN_SSH LIMIT_GUI_TO_LAN=$LIMIT_GUI_TO_LAN REBOOT_AFTER=$REBOOT_AFTER"

  [[ -f "$PVE_KEYRING" ]] || mark_warn "keyring" "Keyring not found at $PVE_KEYRING (verify signing if issues)."

  safe_run_step "disable_enterprise_repos" step_disable_enterprise_repos
  safe_run_step "enable_no_subscription_repo" step_enable_no_subscription_repo
  safe_run_step "disable_ceph_repos" step_disable_ceph_repos
  safe_run_step "apt_update_upgrade" step_apt_update_upgrade
  safe_run_step "harden_ssh" step_harden_ssh
  safe_run_step "limit_gui_firewall" step_limit_gui_firewall
  safe_run_step "remove_subscription_nag" step_remove_subscription_nag

  print_summary

  if [[ "$REBOOT_AFTER" == "yes" ]]; then
    log "Rebooting now..."
    reboot
  else
    log "Reboot recommended when convenient: reboot"
  fi
}

main "$@"
