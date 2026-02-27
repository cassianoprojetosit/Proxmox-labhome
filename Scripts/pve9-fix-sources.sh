#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ==========================================================
# Proxmox VE 9.x - Fix APT Sources (SAFE / deb822)
# Flow (strict):
#   1) Validate environment + files
#   2) Backup targets
#   3) Disable (rename) existing enterprise/ceph sources (no editing)
#   4) Create fresh pve-no-subscription.sources (no editing)
#   5) Validate with apt-get update
#   6) Print report (always)
#
# Notes:
# - Does NOT touch UI/nag/SSH/firewall.
# - Uses rename-to-disable to avoid "Malformed stanza" risks in deb822.
# - Idempotent: re-running is safe.
# ==========================================================

LOG="/var/log/pve9-fix-sources-safe.log"
RUN_TS="$(date +%Y%m%d-%H%M%S)"

PVE_NO_SUB_URI="http://download.proxmox.com/debian/pve"
PVE_KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"
DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
NOSUB_SOURCES="/etc/apt/sources.list.d/pve-no-subscription.sources"

# If "yes", also disables any ceph-related sources (recommended if you won't use Ceph)
DISABLE_CEPH="${DISABLE_CEPH:-yes}"

ts(){ date -Is; }
log(){ echo "[$(ts)] $*" | tee -a "$LOG"; }

declare -A STS MSG
ok(){ STS["$1"]="OK"; MSG["$1"]="${2:-}"; }
warn(){ STS["$1"]="WARN"; MSG["$1"]="${2:-}"; }
fail(){ STS["$1"]="FAIL"; MSG["$1"]="${2:-}"; }

die(){ log "ERROR: $*"; exit 1; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

pve_ver(){
  # pve-manager/9.1.1/...
  pveversion 2>/dev/null | awk -F'/' '{print $2}' | awk -F'-' '{print $1}'
}

detect_suite(){
  # Prefer Debian suite from debian.sources
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
  # Renames file so APT ignores it. Does NOT parse/edit contents (safe for deb822).
  local f="$1"
  [[ -f "$f" ]] || return 0
  local new="${f}.disabled-${RUN_TS}"
  backup_file "$f"
  mv -f "$f" "$new"
  log "Disabled: $f -> $new"
}

print_report(){
  echo
  log "================= REPORT ================="
  printf "\n%-24s %-6s %s\n" "STEP" "STATUS" "DETAILS" | tee -a "$LOG"
  printf "%-24s %-6s %s\n" "----" "------" "-------" | tee -a "$LOG"
  for s in validate backup disable_enterprise disable_ceph create_nosub validate_apt; do
    printf "%-24s %-6s %s\n" "$s" "${STS[$s]:-SKIP}" "${MSG[$s]:-}" | tee -a "$LOG"
  done
  echo | tee -a "$LOG"
  log "Log file: $LOG"
}

trap 'print_report' EXIT

main(){
  mkdir -p "$(dirname "$LOG")" || true
  touch "$LOG" || true

  # ---------------- 1) Validate ----------------
  need_root
  need_cmd pveversion
  need_cmd apt-get
  need_cmd awk
  need_cmd grep
  need_cmd mv
  need_cmd cp
  need_cmd date

  local ver major suite
  ver="$(pve_ver)"
  major="${ver%%.*}"
  suite="$(detect_suite)"

  log "Detected Proxmox VE version: $ver"
  log "Detected Debian suite: $suite"
  log "Note: Proxmox 9 uses deb822 (*.sources); /etc/apt/sources.list may be empty (normal)."

  if [[ "$major" != "9" ]]; then
    fail validate "This script supports Proxmox VE 9.x only (detected $ver)"
    exit 1
  fi

  if [[ ! -f "$PVE_KEYRING" ]]; then
    warn validate "Keyring not found at $PVE_KEYRING (apt may still work if configured elsewhere)"
  else
    ok validate "Environment OK (PVE $ver / suite $suite)"
  fi

  # ---------------- 2) Pre-flight: list candidate files ----------------
  # We do NOT edit existing .sources. We only rename them if enterprise/ceph.
  local candidates=()
  local f
  for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] && candidates+=("$f")
  done

  # If no sources exist at all, that's unusual but not fatal if we can create nosub + debian.sources exists.
  if [[ ${#candidates[@]} -eq 0 && ! -f "$DEBIAN_SOURCES" ]]; then
    fail validate "No APT sources found in /etc/apt/sources.list.d/ and $DEBIAN_SOURCES missing"
    exit 1
  fi

  ok backup "Pre-flight OK (found ${#candidates[@]} source file(s) to inspect)."

  # ---------------- 3) Backup targets we will definitely write ----------------
  # Backup nosub file if it exists (we will overwrite it).
  backup_file "$NOSUB_SOURCES"

  # Backup will also happen for any file we disable (inside disable_by_rename).
  ok backup "Backups prepared (nosub backup created if existed)."

  # ---------------- 4) Disable enterprise (rename) ----------------
  local ent=0
  for f in "${candidates[@]}"; do
    if grep -qE 'enterprise\.proxmox\.com' "$f" || grep -qE 'pve-enterprise' "$f"; then
      disable_by_rename "$f"
      ent=$((ent+1))
    fi
  done
  ok disable_enterprise "Disabled $ent enterprise source file(s) (renamed)."

  # ---------------- 5) Disable ceph (rename) ----------------
  if [[ "$DISABLE_CEPH" == "yes" ]]; then
    local ceph=0
    # Re-scan, because some files may have been renamed already.
    for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
      [[ -f "$f" ]] || continue
      if grep -qiE 'ceph' "$f"; then
        disable_by_rename "$f"
        ceph=$((ceph+1))
      fi
    done
    ok disable_ceph "Disabled $ceph ceph-related source file(s) (renamed)."
  else
    warn disable_ceph "Skipped (DISABLE_CEPH=no)"
  fi

  # ---------------- 6) Create fresh no-subscription deb822 file ----------------
  cat >"$NOSUB_SOURCES" <<EOF
Types: deb
URIs: ${PVE_NO_SUB_URI}
Suites: ${suite}
Components: pve-no-subscription
Signed-By: ${PVE_KEYRING}
EOF
  ok create_nosub "Wrote $NOSUB_SOURCES"

  # ---------------- 7) Validate with apt-get update ----------------
  log "Running apt-get update to validate sources..."
  set +e
  local out rc
  out="$(apt-get update 2>&1)"
  rc=$?
  set -e
  echo "$out" | tee -a "$LOG"

  if [[ $rc -eq 0 ]]; then
    ok validate_apt "apt-get update OK (sources valid)"
  else
    # Fail hard: sources not valid
    fail validate_apt "apt-get update FAILED (see log). Remaining active sources may be malformed or conflicting."
    exit 1
  fi

  log "DONE."
}

main "$@"
