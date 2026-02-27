#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

LOG="/var/log/pve-fix-sources.log"

ts(){ date +%Y%m%d-%H%M%S; }
log(){ echo "[$(date -Is)] $*" | tee -a "$LOG"; }

declare -A STS MSG
ok(){ STS["$1"]="OK"; MSG["$1"]="${2:-}"; }
warn(){ STS["$1"]="WARN"; MSG["$1"]="${2:-}"; }
fail(){ STS["$1"]="FAIL"; MSG["$1"]="${2:-}"; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { log "ERROR: Run as root"; exit 1; }; }
need_pve(){ command -v pveversion >/dev/null 2>&1 || { log "ERROR: pveversion not found"; exit 1; }; }

pve_ver(){
  pveversion 2>/dev/null | awk -F'/' '{print $2}' | awk -F'-' '{print $1}'
}

detect_suite(){
  # Prefer Debian suite from debian.sources if present
  local f="/etc/apt/sources.list.d/debian.sources"
  if [[ -f "$f" ]]; then
    local s
    s="$(grep -m1 -E '^\s*Suites:\s*' "$f" | awk '{print $2}' || true)"
    [[ -n "${s:-}" ]] && { echo "$s"; return 0; }
  fi
  echo "trixie"
}

backup_file(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(ts)"
  log "Backup: ${f}.bak.$(ts)"
}

disable_file(){
  # Disable a sources/list file by renaming it so APT ignores it
  local f="$1"
  [[ -f "$f" ]] || return 0
  backup_file "$f"
  local new="${f}.disabled-$(ts)"
  mv -f "$f" "$new"
  log "Disabled: $f -> $new"
}

print_summary(){
  echo
  log "================= SUMMARY ================="
  printf "\n%-22s %-6s %s\n" "STEP" "STATUS" "DETAILS" | tee -a "$LOG"
  printf "%-22s %-6s %s\n" "----" "------" "-------" | tee -a "$LOG"
  for s in validate disable_enterprise disable_ceph ensure_nosub apt_update; do
    printf "%-22s %-6s %s\n" "$s" "${STS[$s]:-SKIP}" "${MSG[$s]:-}" | tee -a "$LOG"
  done
  echo | tee -a "$LOG"
  log "Log: $LOG"
}

trap 'print_summary' EXIT

main(){
  mkdir -p "$(dirname "$LOG")" || true
  touch "$LOG" || true

  need_root
  need_pve

  local ver major suite
  ver="$(pve_ver)"
  major="${ver%%.*}"
  suite="$(detect_suite)"

  log "Detected Proxmox VE version: $ver"
  log "Detected suite: $suite"
  log "Note: Proxmox 9 uses deb822 (*.sources). /etc/apt/sources.list may be empty (normal)."

  if [[ "$major" != "9" ]]; then
    fail validate "This script is for Proxmox VE 9.x only (detected $ver)"
    exit 1
  fi
  ok validate "PVE 9.x confirmed"

  # --- Disable enterprise sources by RENAMING (safe) ---
  local ent=0
  for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qE 'enterprise\.proxmox\.com' "$f" || grep -qE 'pve-enterprise' "$f"; then
      disable_file "$f"
      ent=$((ent+1))
    fi
  done
  ok disable_enterprise "Disabled $ent enterprise file(s) (renamed)"

  # --- Disable ceph sources by RENAMING (safe) ---
  local ceph=0
  for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qiE 'ceph' "$f"; then
      disable_file "$f"
      ceph=$((ceph+1))
    fi
  done
  ok disable_ceph "Disabled $ceph ceph-related file(s) (renamed)"

  # --- Ensure no-subscription repo exists (deb822) ---
  local nosub="/etc/apt/sources.list.d/pve-no-subscription.sources"
  backup_file "$nosub"
  cat >"$nosub" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${suite}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  ok ensure_nosub "Wrote $nosub"

  # --- Validate apt ---
  log "Running apt-get update to validate sources..."
  set +e
  local out rc
  out="$(apt-get update 2>&1)"
  rc=$?
  set -e
  echo "$out" | tee -a "$LOG"

  if [[ $rc -eq 0 ]]; then
    ok apt_update "apt-get update OK"
  else
    fail apt_update "apt-get update failed (see log). You still have a broken .sources/.list active."
    exit 1
  fi

  log "DONE."
}

main "$@"
