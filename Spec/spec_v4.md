# SPEC v4.0
# Projeto Intensivo 30 Dias – Proxmox Profissional (Lab Real)

**Versão do Proxmox (ambos nós):** Proxmox Virtual Environment 9.1.1 (Debian Trixie)  
**Duração:** 30 dias  
**Carga diária:** 5 horas  
**Objetivo:** dominar Proxmox do básico ao profissional com foco em entregar otimização/virtualização para SMB (pequenas e médias empresas).

---

## 1) Infraestrutura definitiva

### Nó 1 – `pve-node1`
- **IP (LAN):** `192.168.68.70/24`
- **Gateway/DNS:** `192.168.68.1`
- **CPU:** Ryzen 7
- **RAM:** 32 GB
- **Disco:** 1 TB SSD
- **ZFS (instalação):** ZFS em **disco único** (sem redundância)
- **Função:** produção principal do lab

### Nó 2 – `pve-node2`
- **IP (LAN):** `192.168.68.71/24`
- **Gateway/DNS:** `192.168.68.1`
- **CPU:** Ryzen 5
- **RAM:** 12 GB
- **Discos:**
  - **NVMe 2 TB (principal):** ZFS em disco único (`rpool`)
  - **SATA 1 TB (secundário):** reservado para **pool de backup** (criar após instalação)
- **Função:** replicação + backup + failover

### Roteador/LAN
- **Gateway:** `192.168.68.1` (TP-Link Deco)
- **VLANs:** não utilizadas neste lab (opção futura)

---

## 2) Arquitetura de rede do laboratório

### LAN (produção/gerência)
- **Faixa:** `192.168.68.0/24`
- **Nós:**
  - `pve-node1`: `192.168.68.70`
  - `pve-node2`: `192.168.68.71`
- **Observações:**
  - IP fixo (sem DHCP)
  - acesso web: `https://IP:8006`

### Rede de Cluster (isolada logicamente – ainda a configurar)
- **Faixa reservada:** `10.10.10.0/30`
- **IPs planejados:**
  - `pve-node1`: `10.10.10.1/30` (interface física dedicada)
  - `pve-node2`: `10.10.10.2/30` (IP secundário na interface LAN)
- **Regra de ouro:** **sem gateway** na rede de cluster.

---

## 3) Estratégia de Storage (profissional/realista)

### Por que disco único no rpool?
- laboratório com foco em **execução rápida** e **alta performance**
- backups/replicação serão obrigatórios (redundância ≠ backup)

### Estratégia final
- **Node1 (1TB SSD):** produção principal
- **Node2 (2TB NVMe):** produção secundária (recebe réplicas e pode assumir VMs)
- **Node2 (1TB SATA):** **pool dedicado de backup** (separação de função = prática empresarial)

---

## 4) Post-install (padrão profissional para cliente)

### Repositórios (Proxmox 9 / deb822 `.sources`)
- desativar `enterprise.proxmox.com` quando **não há subscription**
- habilitar `pve-no-subscription` quando o cliente não comprar subscription
- Ceph: **opt-in** (desativado no lab)

### Subscription nag (mensagem na UI)
- remover é **opcional**
- **sem hook** (se voltar após update, aplicar novamente)

> Script recomendado (para versionar no GitHub): `pve9-postinstall-hardened.sh`

---

## 5) Cronograma (30 dias)

### Semana 1 – Fundação sólida
- instalação e validação dos nós
- APT sources corretos (PVE 9 / deb822)
- ajustar ZFS/ARC (medição e tuning)
- configurar rede de cluster `10.10.10.0/30`
- criar pool SATA de backup no Node2

### Semana 2 – Infra “empresa fictícia”
- VMs: arquivos, app, DB, firewall, backup
- templates, snapshots, clones
- padrões de naming, tags, pools e permissões

### Semana 3 – Cluster + replicação + falhas
- cluster e corosync usando rede 10.10.10.x
- migração ao vivo
- replicação ZFS
- simular falha do Node1 e recuperar

### Semana 4 – Entrega vendável
- documentação final
- diagrama de rede e storage
- plano de migração (VMware → Proxmox)
- cálculo de economia e proposta técnica
- checklist de operação e DR

---

## 6) Métricas de sucesso

Ao final você deve conseguir:
- instalar Proxmox 9 sem tutorial
- corrigir sources (deb822) com segurança
- criar e operar cluster
- explicar quorum/corosync
- configurar storage ZFS e replicação
- executar backup/restore e DR
- documentar e vender um projeto SMB

---

## 7) Controle de versão

- Esta SPEC é o documento “mestre”.
- Toda mudança importante vira nova versão (v4.1, v4.2…).
- O DOC técnico (guia) complementa esta SPEC com explicações detalhadas.

---

**FIM — SPEC v4.0**
