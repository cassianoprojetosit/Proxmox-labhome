#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

LOG="/var/log/pve9-fix-sources.log"
RUN_TS="$(date +%Y%m%d-%H%M%S)"

PVE_NO_SUB_URI="http://download.proxmox.com/debian/pve"
PVE_KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"
DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
NOSUB_SOURCES="/etc/apt/sources.list.d/pve-no-subscription.sources"

DISABLE_CEPH="${DISABLE_CEPH:-yes}"

ts(){ date -Is; }
log(){ echo "[$(ts)] $*" | tee -a "$LOG" >/dev/null; }

declare -A STS MSG
ok(){ STS["$1"]="OK"; MSG["$1"]="${2:-}"; }
warn(){ STS["$1"]="WARN"; MSG["$1"]="${2:-}"; }
fail(){ STS["$1"]="FAIL"; MSG["$1"]="${2:-}"; }

MAIN_STARTED=0
ERR_STEP="validate"

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { fail validate "Run as root"; exit 1; }; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { fail validate "Missing command: $1"; exit 1; }; }

pve_ver(){
  pveversion 2>/dev/null | awk -F'/' '{print $2}' | awk -F'-' '{print $1}'
}

detect_suite(){
  if [[ -f "$DEBIAN_SOURCES" ]]; then
    local s
    s="$(grep -m1 -E '^\s*Suites:\s*' "$DEBIAN_SOURCES" | awk '{print $2}' || true)"
    [[ -n "${s:-}" ]] && { echo "$s"; return 0; }
  fi
  echo "trixie"
}

backup_file(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.${RUN_TS}"
  log "Backup: ${f}.bak.${RUN_TS}"
}

disable_by_rename(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  local new="${f}.disabled-${RUN_TS}"
  backup_file "$f"
  mv -f "$f" "$new"
  log "Disabled: $f -> $new"
}

print_report(){
  # If main never started, report it clearly
  if [[ "$MAIN_STARTED" -ne 1 ]]; then
    fail validate "main() did not start. File not overwritten correctly or parse/line-ending issue."
  fi

  echo
  echo "[$(ts)] ================= REPORT =================" | tee -a "$LOG"
  printf "\n%-24s %-6s %s\n" "STEP" "STATUS" "DETAILS" | tee -a "$LOG"
  printf "%-24s %-6s %s\n" "----" "------" "-------" | tee -a "$LOG"

  for s in validate backup disable_enterprise disable_ceph create_nosub validate_apt; do
    printf "%-24s %-6s %s\n" "$s" "${STS[$s]:-SKIP}" "${MSG[$s]:-}" | tee -a "$LOG"
  done

  echo | tee -a "$LOG"
  echo "[$(ts)] Log file: $LOG" | tee -a "$LOG"
}

on_err(){
  local rc=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  fail "${ERR_STEP:-validate}" "Error rc=$rc at line=$line cmd=$cmd"
  exit "$rc"
}

trap 'on_err' ERR
trap 'print_report' EXIT

main(){
  MAIN_STARTED=1
  mkdir -p "$(dirname "$LOG")" || true
  : > "$LOG" || true

  log "START run=${RUN_TS}"

  ERR_STEP="validate"
  need_root
  need_cmd pveversion
  need_cmd apt-get
  need_cmd awk
  need_cmd grep
  need_cmd mv
  need_cmd cp
  need_cmd date
  need_cmd tee

  local ver major suite
  ver="$(pve_ver)"
  major="${ver%%.*}"
  suite="$(detect_suite)"

  log "Detected Proxmox VE version: $ver"
  log "Detected Debian suite: $suite"

  if [[ "$major" != "9" ]]; then
    fail validate "This script supports Proxmox VE 9.x only (detected $ver)"
    exit 1
  fi
  ok validate "PVE 9.x confirmed"

  ERR_STEP="backup"
  backup_file "$NOSUB_SOURCES"
  ok backup "Backed up nosub file if it existed"

  ERR_STEP="disable_enterprise"
  local ent=0
  local f
  for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qE 'enterprise\.proxmox\.com' "$f" || grep -qE 'pve-enterprise' "$f"; then
      disable_by_rename "$f"
      ent=$((ent+1))
    fi
  done
  ok disable_enterprise "Disabled $ent enterprise source file(s) (renamed)"

  ERR_STEP="disable_ceph"
  if [[ "$DISABLE_CEPH" == "yes" ]]; then
    local ceph=0
    for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
      [[ -f "$f" ]] || continue
      if grep -qiE 'ceph' "$f"; then
        disable_by_rename "$f"
        ceph=$((ceph+1))
      fi
    done
    ok disable_ceph "Disabled $ceph ceph-related source file(s) (renamed)"
  else
    warn disable_ceph "Skipped (DISABLE_CEPH=no)"
  fi

  ERR_STEP="create_nosub"
  cat >"$NOSUB_SOURCES" <<EOF
Types: deb
URIs: ${PVE_NO_SUB_URI}
Suites: ${suite}
Components: pve-no-subscription
Signed-By: ${PVE_KEYRING}
EOF
  ok create_nosub "Wrote $NOSUB_SOURCES"

  ERR_STEP="validate_apt"
  log "Running apt-get update..."
  set +e
  local out rc
  out="$(apt-get update 2>&1)"
  rc=$?
  set -e
  echo "$out" | tee -a "$LOG" >/dev/null

  if [[ $rc -eq 0 ]]; then
    ok validate_apt "apt-get update OK"
  else
    fail validate_apt "apt-get update FAILED (see log)"
    exit 1
  fi

  log "DONE"
}

log "SCRIPT LOADED run=${RUN_TS} (about to call main)"
main "$@"
