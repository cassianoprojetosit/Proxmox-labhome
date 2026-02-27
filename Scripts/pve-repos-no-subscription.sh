#!/usr/bin/env bash
#
# pve-repos-no-subscription.sh
# ============================
# Configura repositórios APT do Proxmox VE para uso SEM assinatura (no-subscription),
# valida o resultado e executa apt update + full-upgrade.
#
# O que faz:
#   1. Verifica execução como root e versão PVE suportada (8.x / 9.x)
#   2. Faz backup automático de /etc/apt/sources.list e sources.list.d/
#   3. Ajusta fontes: Debian (bookworm/trixie) + Proxmox pve-no-subscription
#   4. Desativa pve-enterprise e Ceph enterprise; ativa Ceph no-subscription
#   5. Valida a configuração aplicada
#   6. Executa apt update e apt full-upgrade -y
#
# Segurança:
#   - Nenhum download/execução de código remoto
#   - Alterações apenas em /etc/apt e /usr/share (apt.conf.d)
#   - Backup obrigatório antes de qualquer alteração
#
# Uso: sudo ./pve-repos-no-subscription.sh
#

set -euo pipefail
shopt -s nullglob

# ------------------------------------------------------------------------------
# Constantes
# ------------------------------------------------------------------------------
readonly SUPPORTED_MAJOR_VERSIONS="8 9"
readonly BACKUP_BASE="/root/apt-sources-backup"
readonly APT_SOURCES_LIST="/etc/apt/sources.list"
readonly APT_SOURCES_D="/etc/apt/sources.list.d"

# ------------------------------------------------------------------------------
# Cores e logging
# ------------------------------------------------------------------------------
readonly C_RED='\033[01;31m'
readonly C_GREEN='\033[1;92m'
readonly C_YELLOW='\033[33m'
readonly C_RESET='\033[m'

log_ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_info()  { echo -e "${C_YELLOW}[*]${C_RESET} $*"; }
log_err()   { echo -e "${C_RED}[ERRO]${C_RESET} $*"; }
log_pass()  { echo -e "${C_GREEN}[PASS]${C_RESET} $*"; }
log_fail()  { echo -e "${C_RED}[FAIL]${C_RESET} $*"; }

# Contador de falhas na validação (global)
VALIDATE_FAIL_COUNT=0

# ------------------------------------------------------------------------------
# Segurança e pré-requisitos
# ------------------------------------------------------------------------------
check_root() {
  if [[ $(id -u) -ne 0 ]]; then
    log_err "Execute como root: sudo $0"
    exit 1
  fi
}

get_pve_version() {
  pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}'
}

get_pve_major_minor() {
  local ver="${1:-}"
  local major minor
  IFS='.' read -r major minor _ <<<"${ver}.0"
  echo "$major $minor"
}

check_pve_version() {
  local version major minor
  version="$(get_pve_version)"
  read -r major minor <<<"$(get_pve_major_minor "$version")"
  if [[ " $SUPPORTED_MAJOR_VERSIONS " != *" $major "* ]]; then
    log_err "Proxmox VE $major não suportado. Suportado: 8.x e 9.x"
    exit 1
  fi
  # Exportar para uso no script
  PVE_MAJOR="$major"
  PVE_MINOR="${minor:-0}"
  PVE_VERSION="$version"
}

# ------------------------------------------------------------------------------
# Backup
# ------------------------------------------------------------------------------
do_backup() {
  local backup_dir="${BACKUP_BASE}-$(date +%Y%m%d-%H%M%S)"
  log_info "Criando backup em $backup_dir"
  mkdir -p "$backup_dir"
  [[ -f "$APT_SOURCES_LIST" ]] && cp -a "$APT_SOURCES_LIST" "$backup_dir/"
  [[ -d "$APT_SOURCES_D" ]]   && cp -a "$APT_SOURCES_D" "$backup_dir/"
  log_ok "Backup concluído: $backup_dir"
  echo "$backup_dir"
}

print_restore_instructions() {
  local backup_dir="$1"
  echo ""
  echo "Backup salvo em: $backup_dir"
  echo "Para reverter:"
  echo "  sudo cp -a \"$backup_dir/sources.list\" /etc/apt/"
  echo "  sudo rm -rf /etc/apt/sources.list.d && sudo cp -a \"$backup_dir/sources.list.d\" /etc/apt/"
  echo "  sudo apt-get update"
}

# ------------------------------------------------------------------------------
# Configuração de repositórios — PVE 8 (Bookworm)
# ------------------------------------------------------------------------------
setup_pve8() {
  log_info "Configurando repositórios para Proxmox VE 8 (Bookworm)..."

  cat >"$APT_SOURCES_LIST" <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF
  echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' >/etc/apt/apt.conf.d/no-bookworm-firmware.conf
  log_ok "Fontes Debian (bookworm) definidas"

  cat >"$APT_SOURCES_D/pve-enterprise.list" <<'EOF'
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF
  log_ok "pve-enterprise desativado"

  cat >"$APT_SOURCES_D/pve-install-repo.list" <<'EOF'
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
  log_ok "pve-no-subscription ativado"

  cat >"$APT_SOURCES_D/ceph.list" <<'EOF'
# deb https://enterprise.proxmox.com/debian/ceph-quincy bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
# deb https://enterprise.proxmox.com/debian/ceph-reef bookworm enterprise
deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
EOF
  log_ok "Ceph: enterprise desativado, no-subscription (ceph-reef) ativo"
}

# ------------------------------------------------------------------------------
# Configuração de repositórios — PVE 9 (Trixie, deb822)
# ------------------------------------------------------------------------------
setup_pve9() {
  log_info "Configurando repositórios para Proxmox VE 9 (Trixie, deb822)..."

  if [[ -f "$APT_SOURCES_LIST" ]] && grep -qE '^\s*deb ' "$APT_SOURCES_LIST" 2>/dev/null; then
    mv "$APT_SOURCES_LIST" "${APT_SOURCES_LIST}.bak"
    log_ok "sources.list legado renomeado para sources.list.bak"
  fi

  cat >"$APT_SOURCES_D/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  log_ok "Fontes Debian (trixie) em debian.sources"

  for f in "$APT_SOURCES_D"/*.sources; do
    [[ -e "$f" ]] || continue
    if grep -q "Components:.*pve-enterprise" "$f" 2>/dev/null; then
      if grep -q "^Enabled:" "$f" 2>/dev/null; then
        sed -i 's/^Enabled:.*/Enabled: false/' "$f"
      else
        echo "Enabled: false" >>"$f"
      fi
      log_ok "pve-enterprise desativado em $f"
    fi
  done
  for f in "$APT_SOURCES_D"/*.list; do
    [[ -e "$f" ]] || continue
    if grep -q "pve-enterprise" "$f" 2>/dev/null; then
      sed -i '/^\s*deb .*pve-enterprise/s/^/# /' "$f"
      log_ok "pve-enterprise comentado em $f"
    fi
  done

  for f in "$APT_SOURCES_D"/*.sources "$APT_SOURCES_D"/*.list; do
    [[ -e "$f" ]] || continue
    if grep -q "enterprise.proxmox.com.*ceph" "$f" 2>/dev/null; then
      if [[ "$f" == *.sources ]]; then
        if grep -q "^Enabled:" "$f" 2>/dev/null; then
          sed -i 's/^Enabled:.*/Enabled: false/' "$f"
        else
          echo "Enabled: false" >>"$f"
        fi
      else
        sed -i '/enterprise.proxmox.com.*ceph/s/^/# /' "$f"
      fi
      log_ok "Ceph enterprise desativado em $f"
    fi
  done

  cat >"$APT_SOURCES_D/proxmox.sources" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  log_ok "pve-no-subscription ativo em proxmox.sources"

  if ! grep -q "download.proxmox.com.*ceph.*no-subscription\|ceph-squid.*no-subscription" "$APT_SOURCES_D"/*.sources "$APT_SOURCES_D"/*.list 2>/dev/null; then
    cat >"$APT_SOURCES_D/ceph.sources" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    log_ok "Ceph no-subscription (ceph-squid) criado"
  else
    log_ok "Ceph no-subscription já presente"
  fi
}

setup_repos() {
  if [[ "$PVE_MAJOR" == "8" ]]; then
    setup_pve8
  elif [[ "$PVE_MAJOR" == "9" ]]; then
    setup_pve9
  else
    log_err "Versão não tratada: PVE_MAJOR=$PVE_MAJOR"
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Validação — PVE 8
# ------------------------------------------------------------------------------
validate_pve8() {
  if grep -qE '^\s*deb\s+.*bookworm' "$APT_SOURCES_LIST" 2>/dev/null; then
    log_pass "Debian bookworm em sources.list"
  else
    log_fail "Debian bookworm não encontrado"
    ((VALIDATE_FAIL_COUNT++)) || true
  fi

  if [[ -f "$APT_SOURCES_D/pve-enterprise.list" ]]; then
    if ! grep -qE '^\s*deb\s+.*pve-enterprise' "$APT_SOURCES_D/pve-enterprise.list" 2>/dev/null; then
      log_pass "pve-enterprise desativado"
    else
      log_fail "pve-enterprise ativo (deveria estar comentado)"
      ((VALIDATE_FAIL_COUNT++)) || true
    fi
  else
    log_fail "pve-enterprise.list não encontrado"
    ((VALIDATE_FAIL_COUNT++)) || true
  fi

  local found_nosub=0
  for f in "$APT_SOURCES_D"/*.list; do
    [[ -e "$f" ]] || continue
    if grep -qE '^\s*deb\s+.*pve-no-subscription' "$f" 2>/dev/null; then
      found_nosub=1
      break
    fi
  done
  if [[ "$found_nosub" -eq 1 ]]; then
    log_pass "pve-no-subscription ativo"
  else
    log_fail "pve-no-subscription não encontrado"
    ((VALIDATE_FAIL_COUNT++)) || true
  fi

  if grep -qE '^\s*deb\s+.*download\.proxmox\.com.*ceph.*no-subscription' "$APT_SOURCES_D/ceph.list" 2>/dev/null; then
    log_pass "Ceph no-subscription configurado"
  else
    log_fail "Ceph no-subscription não encontrado em ceph.list"
    ((VALIDATE_FAIL_COUNT++)) || true
  fi
}

# ------------------------------------------------------------------------------
# Validação — PVE 9
# ------------------------------------------------------------------------------
validate_pve9() {
  if [[ -f "$APT_SOURCES_D/debian.sources" ]]; then
    if grep -qE '^\s*Suites:\s+trixie' "$APT_SOURCES_D/debian.sources" 2>/dev/null; then
      log_pass "Debian trixie em debian.sources"
    else
      log_fail "debian.sources sem suite trixie"
      ((VALIDATE_FAIL_COUNT++)) || true
    fi
  else
    log_fail "debian.sources não encontrado"
    ((VALIDATE_FAIL_COUNT++)) || true
  fi

  local enterprise_ok=1
  for f in "$APT_SOURCES_D"/*.sources "$APT_SOURCES_D"/*.list; do
    [[ -e "$f" ]] || continue
    if grep -q "Components:.*pve-enterprise\|pve-enterprise" "$f" 2>/dev/null; then
      if ! grep -q "^Enabled:\s*false" "$f" 2>/dev/null && ! grep -qE '^\s*#\s*.*pve-enterprise' "$f" 2>/dev/null; then
        enterprise_ok=0
        break
      fi
    fi
  done
  if [[ "$enterprise_ok" -eq 1 ]]; then
    log_pass "pve-enterprise desativado"
  else
    log_fail "pve-enterprise parece ativo"
    ((VALIDATE_FAIL_COUNT++)) || true
  fi

  if [[ -f "$APT_SOURCES_D/proxmox.sources" ]]; then
    if grep -q "Components:.*pve-no-subscription" "$APT_SOURCES_D/proxmox.sources" 2>/dev/null; then
      if grep -q "^Enabled:\s*false" "$APT_SOURCES_D/proxmox.sources" 2>/dev/null; then
        log_fail "proxmox.sources tem Enabled: false"
        ((VALIDATE_FAIL_COUNT++)) || true
      else
        log_pass "pve-no-subscription ativo em proxmox.sources"
      fi
    else
      log_fail "proxmox.sources sem pve-no-subscription"
      ((VALIDATE_FAIL_COUNT++)) || true
    fi
  else
    log_fail "proxmox.sources não encontrado"
    ((VALIDATE_FAIL_COUNT++)) || true
  fi

  local ceph_ent_ok=1
  for f in "$APT_SOURCES_D"/*.sources "$APT_SOURCES_D"/*.list; do
    [[ -e "$f" ]] || continue
    if grep -q "enterprise.proxmox.com.*ceph" "$f" 2>/dev/null; then
      if ! grep -q "^Enabled:\s*false" "$f" 2>/dev/null && ! grep -qE '^\s*#\s*.*enterprise.*ceph' "$f" 2>/dev/null; then
        ceph_ent_ok=0
        break
      fi
    fi
  done
  if [[ "$ceph_ent_ok" -eq 1 ]]; then
    log_pass "Ceph enterprise desativado"
  else
    log_fail "Ceph enterprise parece ativo"
    ((VALIDATE_FAIL_COUNT++)) || true
  fi

  local ceph_nosub=0
  for f in "$APT_SOURCES_D/ceph.sources" "$APT_SOURCES_D/ceph.list"; do
    [[ -e "$f" ]] || continue
    if grep -q "ceph-squid\|ceph-reef\|ceph-quincy\|/ceph" "$f" 2>/dev/null && grep -q "no-subscription\|pve-no-subscription" "$f" 2>/dev/null; then
      if [[ "$f" == *.sources ]]; then
        grep -q "^Enabled:\s*false" "$f" 2>/dev/null && continue
      else
        grep -qE '^\s*#\s*deb\s+.*ceph.*no-subscription' "$f" 2>/dev/null && continue
      fi
      ceph_nosub=1
      break
    fi
  done
  if [[ "$ceph_nosub" -eq 1 ]]; then
    log_pass "Ceph no-subscription configurado"
  else
    log_fail "Ceph no-subscription não encontrado ou desativado"
    ((VALIDATE_FAIL_COUNT++)) || true
  fi
}

validate_repos() {
  VALIDATE_FAIL_COUNT=0
  echo ""
  echo "=============================================="
  echo "  Validação dos repositórios (PVE $PVE_MAJOR)"
  echo "=============================================="
  if [[ "$PVE_MAJOR" == "8" ]]; then
    validate_pve8
  elif [[ "$PVE_MAJOR" == "9" ]]; then
    validate_pve9
  fi
  echo "=============================================="
  if [[ "$VALIDATE_FAIL_COUNT" -eq 0 ]]; then
    echo -e "  ${C_GREEN}Validação: tudo OK${C_RESET}"
  else
    echo -e "  ${C_RED}Validação: $VALIDATE_FAIL_COUNT falha(s)${C_RESET}"
  fi
  echo "=============================================="
  echo ""
}

# ------------------------------------------------------------------------------
# Apt update e full-upgrade
# ------------------------------------------------------------------------------
run_apt_update_upgrade() {
  log_info "Executando apt update..."
  if ! apt-get update -y; then
    log_err "apt update falhou"
    exit 1
  fi
  log_ok "apt update concluído"
  echo ""

  log_info "Executando apt full-upgrade -y..."
  if ! apt-get full-upgrade -y; then
    log_err "apt full-upgrade falhou"
    exit 1
  fi
  log_ok "apt full-upgrade concluído"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  check_root
  check_pve_version

  echo ""
  echo "=============================================="
  echo "  Proxmox VE — Repositórios no-subscription"
  echo "  Versão: $PVE_VERSION (major $PVE_MAJOR)"
  echo "=============================================="
  echo ""

  local backup_dir
  backup_dir="$(do_backup)"
  echo ""

  setup_repos
  echo ""

  validate_repos
  run_apt_update_upgrade

  print_restore_instructions "$backup_dir"
  echo ""
  log_ok "Script finalizado."
}

main "$@"
