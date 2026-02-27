#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

LOG="/var/log/pve9-fix-sources-safe.log"

ts(){ date +%Y%m%d-%H%M%S; }
log(){ echo "[$(date -Is)] $*" | tee -a "$LOG"; }

declare -A STEP_STATUS STEP_DETAIL
ok(){ STEP_STATUS["$1"]="OK"; STEP_DETAIL["$1"]="${2:-}"; }
warn(){ STEP_STATUS["$1"]="WARN"; STEP_DETAIL["$1"]="${2:-}"; }
fail(){ STEP_STATUS["$1"]="FAIL"; STEP_DETAIL["$1"]="${2:-}"; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { log "ERROR: run as root"; exit 1; }; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }; }

pve_ver(){
  # pve-manager/9.1.1/...
  pveversion 2>/dev/null | awk -F'/' '{print $2}' | awk -F'-' '{print $1}'
}

detect_suite(){
  # Prefer reading Suites from debian.sources (deb822)
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

disable_source_file(){
  # Renames a .sources file to make APT ignore it (safe, no parsing issues)
  local f="$1"
  [[ -f "$f" ]] || return 0
  local new="${f}.disabled-$(ts)"
  backup_file "$f"
  mv -f "$f" "$new"
  log "Disabled (renamed): $f -> $new"
}

print_summary(){
  echo
  log "================= SUMMARY ================="
  printf "\n%-26s %-6s %s\n" "STEP" "STATUS" "DETAILS" | tee -a "$LOG"
  printf "%-26s %-6s %s\n" "----" "------" "-------" | tee -a "$LOG"

  local steps=("validate_env" "disable_enterprise" "disable_ceph" "ensure_nosub" "apt_update")
  for s in "${steps[@]}"; do
    printf "%-26s %-6s %s\n" "$s" "${STEP_STATUS[$s]:-SKIP}" "${STEP_DETAIL[$s]:-}" | tee -a "$LOG"
  done

  echo | tee -a "$LOG"
  log "Log file: $LOG"
}

trap 'print_summary' EXIT

main(){
  mkdir -p "$(dirname "$LOG")" || true
  touch "$LOG" || true

  need_root
  need_cmd pveversion
  need_cmd apt-get
  need_cmd grep
  need_cmd awk

  local ver major suite
  ver="$(pve_ver)"
  major="${ver%%.*}"
  suite="$(detect_suite)"

  log "Detected Proxmox VE version: $ver (major=$major)"
  log "Detected Debian suite: $suite"

  if [[ "$major" != "9" ]]; then
    fail "validate_env" "This script is for Proxmox VE 9.x only (detected $ver)"
    exit 1
  fi
  ok "validate_env" "Environment OK (PVE $ver / suite $suite)"

  # --- Disable enterprise sources safely by renaming files ---
  local ent_touched=0
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE 'enterprise\.proxmox\.com' "$f" || grep -qE '^\s*Components:\s*.*pve-enterprise' "$f"; then
      disable_source_file "$f"
      ent_touched=$((ent_touched+1))
    fi
  done
  if [[ $ent_touched -gt 0 ]]; then
    ok "disable_enterprise" "Disabled $ent_touched enterprise source file(s)"
  else
    ok "disable_enterprise" "No enterprise sources found"
  fi

  # --- Disable ceph sources safely (optional but recommended if you won't use Ceph) ---
  local ceph_touched=0
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qiE 'ceph' "$f"; then
      disable_source_file "$f"
      ceph_touched=$((ceph_touched+1))
    fi
  done
  if [[ $ceph_touched -gt 0 ]]; then
    ok "disable_ceph" "Disabled $ceph_touched ceph-related source file(s)"
  else
    ok "disable_ceph" "No ceph sources found"
  fi

  # --- Ensure pve-no-subscription deb822 source exists and is enabled ---
  local nosub="/etc/apt/sources.list.d/pve-no-subscription.sources"
  backup_file "$nosub"
  cat >"$nosub" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${suite}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  ok "ensure_nosub" "Wrote $nosub"

  # --- Validate ---
  log "Running apt-get update to validate sources..."
  set +e
  local out rc
  out="$(apt-get update 2>&1)"
  rc=$?
  set -e
  echo "$out" | tee -a "$LOG"

  if [[ $rc -eq 0 ]]; then
    ok "apt_update" "apt-get update OK (sources valid)"
  else
    # common errors: malformed stanza, 401 unauthorized, etc.
    fail "apt_update" "apt-get update failed (see log). Fix remaining .sources/.list files."
    exit 1
  fi

  log "DONE."
}

main "$@"
