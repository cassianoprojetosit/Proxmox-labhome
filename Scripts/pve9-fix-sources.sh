#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

LOG="/var/log/pve-fix-sources.log"
ts(){ date +%Y%m%d-%H%M%S; }
log(){ echo "[$(date -Is)] $*" | tee -a "$LOG"; }
die(){ log "ERROR: $*"; exit 1; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root"; }
need_pve(){ command -v pveversion >/dev/null 2>&1 || die "pveversion not found (not Proxmox?)"; }

pve_ver(){
  # pve-manager/9.1.6/...
  pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}'
}

backup_file(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(ts)"
  log "Backup: ${f}.bak.$(ts)"
}

deb822_set_enabled(){
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

main(){
  need_root
  need_pve
  mkdir -p "$(dirname "$LOG")"; touch "$LOG" || true

  local ver major
  ver="$(pve_ver)"
  major="${ver%%.*}"
  log "Detected Proxmox VE version: $ver"

  [[ "$major" == "9" ]] || die "This script is for Proxmox VE 9.x only (detected $ver)."

  log "APT format note: Proxmox 9 uses deb822 (*.sources). /etc/apt/sources.list may be empty (normal)."

  # 1) Disable any enterprise repos (PVE/Ceph) via Enabled: no
  log "Disabling enterprise repositories (if present)..."
  local changed=0
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE 'enterprise\.proxmox\.com' "$f" || grep -qE '^Components:.*pve-enterprise' "$f"; then
      deb822_set_enabled "$f" "no"
      log "Disabled enterprise in: $f"
      changed=$((changed+1))
    fi
  done
  log "Enterprise disable pass done (touched $changed file(s))."

  # 2) Ensure pve-no-subscription repo exists/enabled
  local nosub="/etc/apt/sources.list.d/pve-no-subscription.sources"
  log "Ensuring pve-no-subscription repo: $nosub"
  backup_file "$nosub"
  cat >"$nosub" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: yes
EOF
  log "Wrote: $nosub"

  # 3) Optional: disable Ceph sources entirely (common if you’re not using Ceph)
  # If you want to keep Ceph, comment this block.
  log "Disabling Ceph sources (safe if you are not using Ceph)..."
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qiE 'ceph' "$f"; then
      deb822_set_enabled "$f" "no"
      log "Disabled ceph in: $f"
    fi
  done

  # 4) Validate with apt-get update
  log "Running apt-get update to validate sources..."
  apt-get update 2>&1 | tee -a "$LOG"

  log "DONE. If apt-get update completed without 401, sources are correct."
  log "Log: $LOG"
}

main "$@"
