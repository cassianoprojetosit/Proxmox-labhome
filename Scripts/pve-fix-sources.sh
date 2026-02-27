#!/usr/bin/env bash

# Script: configurar-sources-proxmox.sh
# Descrição: Corrige problemas nos sources e configura corretamente para o Proxmox VE
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
declare -a arquivos_removidos=()
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

# Função para limpar arquivos corrompidos
limpar_arquivos_corrompidos() {
    msg_info "Verificando arquivos de sources corrompidos"
    
    local corrompidos=0
    
    # Verifica arquivos .bak que estão causando erro
    if [[ -d /etc/apt/sources.list.d ]]; then
        while IFS= read -r -d '' arquivo; do
            if [[ "$arquivo" == *.bak* ]] || [[ "$arquivo" == *~ ]]; then
                criar_backup "$arquivo"
                rm -f "$arquivo"
                arquivos_removidos+=("$arquivo (arquivo backup/temp)")
                registrar_acao "Arquivo temporário removido: $arquivo"
                corrompidos=$((corrompidos + 1))
            fi
        done < <(find /etc/apt/sources.list.d/ -type f -name "*.bak*" -o -name "*~" -print0 2>/dev/null || true)
    fi
    
    if [[ $corrompidos -gt 0 ]]; then
        msg_ok "$corrompidos arquivos temporários removidos"
    else
        msg_ok "Nenhum arquivo temporário encontrado"
    fi
}

# Função para detectar versão do Proxmox manualmente
detectar_versao_manual() {
    local versao=""
    
    # Tenta detectar pela versão do kernel Proxmox
    if uname -r | grep -q "pve"; then
        local kernel_ver
        kernel_ver=$(uname -r)
        
        # PVE8 usa kernel 6.x, PVE9 usa kernel 6.x também, então não é tão confiável
        # Vamos tentar por outros métodos
        
        # Verifica se existe o arquivo de versão do PVE
        if [[ -f /etc/pve/version ]]; then
            versao=$(cat /etc/pve/version | cut -d'.' -f1,2)
        fi
    fi
    
    # Se não conseguiu, pergunta ao usuário mostrando o erro atual
    if [[ -z "$versao" ]]; then
        echo ""
        msg_warning "Não foi possível detectar automaticamente a versão do Proxmox devido a erros nos sources"
        echo ""
        echo "Erro detectado:"
        echo "  - Arquivos .bak com extensão inválida"
        echo "  - Malformed stanza nos arquivos .sources"
        echo ""
        echo "Selecione a versão do Proxmox:"
        echo "1) Proxmox VE 8.x (Debian 12/Bookworm) - MAIS COMUM"
        echo "2) Proxmox VE 9.x (Debian 13/Trixie)"
        echo ""
        read -p "Escolha uma opção (1 ou 2) [padrão: 1]: " versao_escolhida
        
        case "${versao_escolhida:-1}" in
            1) versao="8.0" ;;
            2) versao="9.0" ;;
            *) 
                msg_warning "Opção inválida. Usando PVE8 como padrão"
                versao="8.0"
                ;;
        esac
    fi
    
    echo "$versao"
}

# Função para limpar tudo e começar do zero
limpar_tudo() {
    msg_info "Preparando para reconfigurar todos os sources do zero"
    
    # Backup de TODOS os arquivos relacionados a sources
    [[ -f /etc/apt/sources.list ]] && criar_backup "/etc/apt/sources.list"
    
    if [[ -d /etc/apt/sources.list.d ]]; then
        while IFS= read -r -d '' arquivo; do
            criar_backup "$arquivo"
        done < <(find /etc/apt/sources.list.d/ -type f -print0 2>/dev/null || true)
    fi
    
    # Remove todos os arquivos de sources
    rm -f /etc/apt/sources.list 2>/dev/null || true
    rm -rf /etc/apt/sources.list.d/* 2>/dev/null || true
    
    # Recria o diretório limpo
    mkdir -p /etc/apt/sources.list.d
    
    registrar_acao "Todos os sources antigos foram removidos"
    msg_ok "Diretório de sources limpo"
}

# Função para criar sources mínimos funcionais
criar_sources_minimos() {
    local versao="$1"
    local major="${versao%%.*}"
    
    msg_info "Criando configuração mínima de sources"
    
    case "$major" in
        8)
            # Sources mínimos para PVE8
            cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
            arquivos_criados+=("/etc/apt/sources.list (configuração mínima)")
            ;;
        9)
            # Sources mínimos para PVE9 (formato deb822)
            cat > /etc/apt/sources.list.d/debian.sources << 'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
            arquivos_criados+=("/etc/apt/sources.list.d/debian.sources (configuração mínima)")
            ;;
        *)
            # Fallback para PVE8
            cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
            arquivos_criados+=("/etc/apt/sources.list (configuração mínima - fallback)")
            ;;
    esac
    
    registrar_acao "Sources mínimos criados para PVE${major}"
    msg_ok "Sources mínimos configurados"
}

# Função para configurar Proxmox 8 (Bookworm) - Completa
configurar_pve8() {
    msg_info "Configurando sources completos para Proxmox 8 (Bookworm)"
    
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
    
    # Desativa aviso de non-free-firmware
    echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' > /etc/apt/apt.conf.d/no-bookworm-firmware.conf
    arquivos_criados+=("/etc/apt/apt.conf.d/no-bookworm-firmware.conf")
    
    registrar_acao "Sources completos configurados para PVE8"
    msg_ok "Sources do Proxmox 8 configurados"
}

# Função para configurar Proxmox 9 (Trixie) - Completa
configurar_pve9() {
    msg_info "Configurando sources completos para Proxmox 9 (Trixie) no formato deb822"
    
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
    
    # Ceph (opcional, comentado)
    cat > /etc/apt/sources.list.d/ceph.sources << 'EOF'
# Types: deb
# URIs: http://download.proxmox.com/debian/ceph-squid
# Suites: trixie
# Components: no-subscription
# Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    arquivos_criados+=("/etc/apt/sources.list.d/ceph.sources")
    
    registrar_acao "Sources completos configurados para PVE9"
    msg_ok "Sources do Proxmox 9 configurados no formato deb822"
}

# Função para validar configuração
validar_configuracao() {
    msg_info "Validando configuração dos sources"
    
    local erros=0
    
    echo ""
    echo "Executando apt update (pode levar alguns segundos)..."
    
    # Executa apt update e captura saída
    if apt update 2>&1 | tee /tmp/apt-update.log; then
        if grep -q "Failed to fetch" /tmp/apt-update.log; then
            msg_warning "Apt update concluído com alguns avisos"
            registrar_acao "AVISO: Alguns repositórios podem ter problemas"
        else
            msg_ok "Apt update executado com sucesso"
            registrar_acao "Apt update validado com sucesso"
        fi
    else
        msg_error "Falha ao executar apt update"
        erros=1
        registrar_acao "ERRO: Falha no apt update"
    fi
    
    # Mostra o pveversion agora para confirmar
    if command -v pveversion &>/dev/null; then
        echo ""
        echo "Status do PVE após correção:"
        pveversion 2>/dev/null | head -1 || echo "Pode ser necessário reiniciar o serviço"
    fi
    
    rm -f /tmp/apt-update.log
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
Versão do Proxmox configurada: $versao
Diretório de backup: $BACKUP_DIR

ARQUIVOS COM BACKUP REALIZADO:
$(printf '%s\n' "${arquivos_backup[@]:-Nenhum}")

ARQUIVOS REMOVIDOS:
$(printf '%s\n' "${arquivos_removidos[@]:-Nenhum}")

ARQUIVOS MODIFICADOS/REMOVIDOS:
$(printf '%s\n' "${arquivos_modificados[@]:-Nenhum}")

ARQUIVOS CRIADOS:
$(printf '%s\n' "${arquivos_criados[@]:-Nenhum}")

AÇÕES REALIZADAS:
$(printf '%s\n' "${acoes_realizadas[@]:-Nenhuma}")

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
    echo "  CORREÇÃO E CONFIGURAÇÃO DE SOURCES"
    echo "         DO PROXMOX VE"
    echo "=========================================="
    echo ""
    echo "Problemas detectados no seu sistema:"
    echo "  - Arquivos .bak com extensão inválida"
    echo "  - Malformed stanza em arquivos .sources"
    echo ""
    
    # Confirmação do usuário
    read -p "Este script irá CORRIGIR e reconfigurar os sources do APT. Deseja continuar? (s/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        echo "Operação cancelada."
        exit 0
    fi
    
    # Cria diretório de backup
    mkdir -p "$BACKUP_DIR"
    msg_ok "Diretório de backup criado: $BACKUP_DIR"
    
    # Passo 1: Limpar arquivos corrompidos
    limpar_arquivos_corrompidos
    
    # Passo 2: Detectar versão
    msg_info "Detectando versão do Proxmox"
    local PVE_VERSION
    PVE_VERSION="$(detectar_versao_manual)"
    echo -e "${BFR} ${CM} ${GN}Versão selecionada: Proxmox VE ${PVE_VERSION}${CL}"
    
    # Passo 3: Limpar tudo
    limpar_tudo
    
    # Passo 4: Criar sources mínimos primeiro
    criar_sources_minimos "$PVE_VERSION"
    
    # Passo 5: Tentar apt update com sources mínimos
    msg_info "Testando configuração mínima"
    if apt update &>/dev/null; then
        msg_ok "Configuração mínima funcionou"
    else
        msg_warning "Configuração mínima ainda com problemas, mas continuando..."
    fi
    
    # Passo 6: Perguntar se quer configuração completa
    echo ""
    read -p "Aplicar configuração COMPLETA (com todos os repositórios) ou apenas a configuração mínima? (c=completa/m=mínima) [padrão: completa]: " -n 1 -r config_tipo
    echo ""
    
    case "${config_tipo:-c}" in
        c|C|completa)
            case "${PVE_VERSION%%.*}" in
                8) configurar_pve8 ;;
                9) configurar_pve9 ;;
                *) configurar_pve8 ;;  # fallback
            esac
            ;;
        *)
            msg_ok "Mantendo apenas configuração mínima"
            ;;
    esac
    
    # Passo 7: Validar configuração final
    validar_configuracao
    
    # Passo 8: Gerar relatório
    gerar_relatorio "$PVE_VERSION"
    
    echo ""
    echo "=========================================="
    echo "Configuração concluída!"
    echo "Backup dos arquivos originais: $BACKUP_DIR"
    echo "Relatório: $REPORT_FILE"
    echo ""
    echo "Comandos recomendados:"
    echo "  apt update              # Atualizar lista de pacotes"
    echo "  apt upgrade             # Atualizar pacotes"
    echo "  pveversion              # Verificar versão do PVE"
    echo "=========================================="
}

# Executa função principal
main "$@"
