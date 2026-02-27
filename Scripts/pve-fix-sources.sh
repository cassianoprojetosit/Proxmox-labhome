#!/usr/bin/env bash

# Script: configurar-sources-proxmox.sh
# Descrição: Configura automaticamente os sources do Proxmox VE baseado na versão
# Autor: Baseado no script original da comunidade ProxmoxVE Helper Scripts
# Licença: MIT

set -euo pipefail
shopt -s inherit_errexit nullglob

# Cores para output
readonly RD='\033[01;31m'
readonly YW='\033[33m'
readonly GN='\033[1;92m'
readonly CL='\033[m'
readonly BFR='\r\033[K'
readonly HOLD="-"
readonly CM="${GN}✓${CL}"
readonly CROSS="${RD}✗${CL}"

# Diretório de backup
readonly BACKUP_DIR="/root/backup-sources-$(date +%Y%m%d-%H%M%S)"
readonly REPORT_FILE="/root/relatorio-sources-$(date +%Y%m%d-%H%M%S).txt"

# Arrays para relatório
declare -a arquivos_modificados=()
declare -a arquivos_backup=()
declare -a arquivos_criados=()
declare -a acoes_realizadas=()

# Funções auxiliares
msg_info() {
    echo -ne " ${HOLD} ${YW}${1}...${CL}"
}

msg_ok() {
    echo -e "${BFR} ${CM} ${GN}${1}${CL}"
}

msg_error() {
    echo -e "${BFR} ${CROSS} ${RD}${1}${CL}"
}

msg_warning() {
    echo -e "${BFR} ${YW}⚠ ${1}${CL}"
}

registrar_acao() {
    acoes_realizadas+=("$(date '+%Y-%m-%d %H:%M:%S') - $1")
}

# Função para criar backup de arquivo
criar_backup() {
    local arquivo="$1"
    if [[ -f "$arquivo" ]]; then
        local destino="${BACKUP_DIR}${arquivo}"
        mkdir -p "$(dirname "$destino")"
        cp "$arquivo" "$destino"
        arquivos_backup+=("$arquivo -> $destino")
        registrar_acao "Backup criado: $arquivo"
        return 0
    fi
    return 1
}

# Função para validar arquivo sources
validar_arquivo_sources() {
    local arquivo="$1"
    local tipo="$2" # "list" ou "sources"
    
    if [[ ! -f "$arquivo" ]]; then
        return 1
    fi
    
    case "$tipo" in
        "list")
            # Verifica se tem pelo menos uma entrada válida
            grep -qE '^deb ' "$arquivo" && return 0 || return 1
            ;;
        "sources")
            # Verifica se tem a estrutura básica do deb822
            grep -q "^Types:" "$arquivo" && return 0 || return 1
            ;;
    esac
    return 1
}

# Função para obter versão do Proxmox
get_pve_version() {
    local pve_ver
    if ! pve_ver="$(pveversion 2>/dev/null | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"; then
        msg_error "Não foi possível determinar a versão do Proxmox"
        exit 1
    fi
    echo "$pve_ver"
}

get_pve_major_minor() {
    local ver="$1"
    local major minor
    IFS='.' read -r major minor _ <<<"$ver"
    echo "$major $minor"
}

# Função para limpar arquivos antigos
limpar_arquivos_antigos() {
    msg_info "Limpando arquivos de configuração antigos"
    
    # Backup dos arquivos existentes
    local arquivos_para_backup=()
    
    # Adiciona sources.list se existir
    [[ -f /etc/apt/sources.list ]] && arquivos_para_backup+=("/etc/apt/sources.list")
    
    # Adiciona todos os .list e .sources do diretório
    while IFS= read -r -d '' arquivo; do
        arquivos_para_backup+=("$arquivo")
    done < <(find /etc/apt/sources.list.d/ -type f \( -name "*.list" -o -name "*.sources" \) -print0 2>/dev/null || true)
    
    # Cria backups
    for arquivo in "${arquivos_para_backup[@]}"; do
        if criar_backup "$arquivo"; then
            arquivos_modificados+=("$arquivo")
        fi
    done
    
    # Remove arquivos antigos (mas mantém os backups)
    rm -f /etc/apt/sources.list
    rm -f /etc/apt/sources.list.d/*.list
    rm -f /etc/apt/sources.list.d/*.sources
    
    registrar_acao "Arquivos antigos removidos"
    msg_ok "Arquivos antigos removidos (backups salvos em ${BACKUP_DIR})"
}

# Função para configurar Proxmox 8 (Bookworm)
configurar_pve8() {
    msg_info "Configurando sources para Proxmox 8 (Bookworm)"
    
    # Cria sources.list principal
    cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF
    arquivos_criados+=("/etc/apt/sources.list")
    
    # Desativa enterprise (comentado)
    cat > /etc/apt/sources.list.d/pve-enterprise.list << 'EOF'
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF
    arquivos_criados+=("/etc/apt/sources.list.d/pve-enterprise.list")
    
    # Adiciona no-subscription
    cat > /etc/apt/sources.list.d/pve-install-repo.list << 'EOF'
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
    arquivos_criados+=("/etc/apt/sources.list.d/pve-install-repo.list")
    
    # Configura Ceph (comentado)
    cat > /etc/apt/sources.list.d/ceph.list << 'EOF'
# deb https://enterprise.proxmox.com/debian/ceph-quincy bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
# deb https://enterprise.proxmox.com/debian/ceph-reef bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
EOF
    arquivos_criados+=("/etc/apt/sources.list.d/ceph.list")
    
    # Configura pvetest (comentado)
    cat > /etc/apt/sources.list.d/pvetest-for-beta.list << 'EOF'
# deb http://download.proxmox.com/debian/pve bookworm pvetest
EOF
    arquivos_criados+=("/etc/apt/sources.list.d/pvetest-for-beta.list")
    
    # Desativa aviso de non-free-firmware
    echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' > /etc/apt/apt.conf.d/no-bookworm-firmware.conf
    arquivos_criados+=("/etc/apt/apt.conf.d/no-bookworm-firmware.conf")
    
    registrar_acao "Sources configurados para PVE8"
    msg_ok "Sources do Proxmox 8 configurados"
}

# Função para configurar Proxmox 9 (Trixie)
configurar_pve9() {
    msg_info "Configurando sources para Proxmox 9 (Trixie) no formato deb822"
    
    # Sources Debian
    cat > /etc/apt/sources.list.d/debian.sources << 'EOF'
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
    arquivos_criados+=("/etc/apt/sources.list.d/debian.sources")
    
    # Proxmox no-subscription
    cat > /etc/apt/sources.list.d/proxmox.sources << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    arquivos_criados+=("/etc/apt/sources.list.d/proxmox.sources")
    
    # Ceph (opcional, comentado por padrão)
    cat > /etc/apt/sources.list.d/ceph.sources << 'EOF'
# Types: deb
# URIs: http://download.proxmox.com/debian/ceph-squid
# Suites: trixie
# Components: no-subscription
# Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    arquivos_criados+=("/etc/apt/sources.list.d/ceph.sources")
    
    # pvetest (desabilitado)
    cat > /etc/apt/sources.list.d/pve-test.sources << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-test
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
EOF
    arquivos_criados+=("/etc/apt/sources.list.d/pve-test.sources")
    
    registrar_acao "Sources configurados para PVE9 (deb822)"
    msg_ok "Sources do Proxmox 9 configurados no formato deb822"
}

# Função para validar configuração
validar_configuracao() {
    msg_info "Validando configuração dos sources"
    
    local erros=0
    local avisos=0
    
    # Testa apt update
    if apt update 2>&1 | grep -q "Failed to fetch"; then
        msg_warning "Apt update encontrou alguns erros, mas pode funcionar"
        avisos=$((avisos + 1))
        registrar_acao "AVISO: Apt update reportou falhas em alguns repositórios"
    elif apt update &>/dev/null; then
        msg_ok "Apt update executado com sucesso"
        registrar_acao "Apt update validado com sucesso"
    else
        msg_error "Falha ao executar apt update"
        erros=$((erros + 1))
        registrar_acao "ERRO: Falha no apt update"
    fi
    
    return $erros
}

# Função para gerar relatório
gerar_relatorio() {
    local versao="$1"
    local data_execucao
    data_execucao=$(date '+%Y-%m-%d %H:%M:%S')
    
    cat > "$REPORT_FILE" << EOF
==============================================
 RELATÓRIO DE CONFIGURAÇÃO DOS SOURCES
==============================================
Data da execução: $data_execucao
Versão do Proxmox: $versao
Diretório de backup: $BACKUP_DIR

ARQUIVOS COM BACKUP REALIZADO:
$(printf '%s\n' "${arquivos_backup[@]:-Nenhum}")

ARQUIVOS MODIFICADOS/REMOVIDOS:
$(printf '%s\n' "${arquivos_modificados[@]:-Nenhum}")

ARQUIVOS CRIADOS:
$(printf '%s\n' "${arquivos_criados[@]:-Nenhum}")

AÇÕES REALIZADAS:
$(printf '%s\n' "${acoes_realizada[@]:-Nenhuma}")

STATUS DA VALIDAÇÃO:
$(if [[ ${#arquivos_criados[@]} -gt 0 ]]; then
    echo "✓ Configuração aplicada com sucesso"
else
    echo "✗ Falha na configuração"
fi)

==============================================
 Para restaurar os backups:
   cp -r $BACKUP_DIR/* /
==============================================
EOF
    
    msg_ok "Relatório gerado: $REPORT_FILE"
}

# Função principal
main() {
    clear
    echo "=========================================="
    echo "  CONFIGURADOR DE SOURCES DO PROXMOX VE"
    echo "=========================================="
    echo ""
    
    # Confirmação do usuário
    read -p "Este script irá reconfigurar os sources do APT. Deseja continuar? (s/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        echo "Operação cancelada."
        exit 0
    fi
    
    # Cria diretório de backup
    mkdir -p "$BACKUP_DIR"
    msg_ok "Diretório de backup criado: $BACKUP_DIR"
    
    # Detecta versão do Proxmox
    msg_info "Detectando versão do Proxmox VE"
    local PVE_VERSION PVE_MAJOR PVE_MINOR
    PVE_VERSION="$(get_pve_version)"
    read -r PVE_MAJOR PVE_MINOR <<<"$(get_pve_major_minor "$PVE_VERSION")"
    msg_ok "Versão detectada: Proxmox VE $PVE_VERSION"
    
    # Limpa configurações antigas
    limpar_arquivos_antigos
    
    # Configura baseado na versão
    case "$PVE_MAJOR" in
        8)
            configurar_pve8
            ;;
        9)
            configurar_pve9
            ;;
        *)
            msg_error "Versão não suportada: $PVE_MAJOR"
            exit 1
            ;;
    esac
    
    # Valida configuração
    validar_configuracao
    
    # Gera relatório
    gerar_relatorio "$PVE_VERSION"
    
    echo ""
    echo "=========================================="
    echo "Configuração concluída!"
    echo "Backup dos arquivos originais: $BACKUP_DIR"
    echo "Relatório: $REPORT_FILE"
    echo ""
    echo "Recomenda-se executar: apt update && apt upgrade"
    echo "=========================================="
}

# Executa função principal
main "$@"
