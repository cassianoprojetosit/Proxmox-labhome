# DOC v3.0
# Guia Técnico – Proxmox VE 9.x (Trixie): Instalação, ZFS, Repositórios e Pós-Instalação

Este documento é um “manual auxiliar” do laboratório.  
Ele explica opções e decisões técnicas para que qualquer pessoa consiga reproduzir o lab com segurança.

---

## 1) Instalação: opções de ZFS (tela de Filesystem)

### ZFS (visão rápida)
ZFS é sistema de arquivos + gerenciador de volumes com:
- integridade por checksums (protege contra corrupção silenciosa)
- snapshots e clones instantâneos
- compressão transparente
- replicação incremental
- cache em RAM (ARC)

### ashift
Define o bloco lógico (alinhamento).  
- **12 = 4K**, recomendado para SSDs modernos (evita perda de performance).

### compress
Compressão no dataset.
- **lz4** é recomendada para Proxmox/VMs porque:
  - muito rápida
  - baixo custo de CPU
  - normalmente reduz espaço e pode melhorar leitura (menos I/O real)

### checksum
- Deve ficar **ON** (base do ZFS para detectar corrupção).

### copies
- `1` é padrão (não duplica blocos).
- valores maiores duplicam blocos e gastam mais espaço (uso bem específico).

### ARC max size
ARC = cache de leitura do ZFS em RAM.
- aumentar ARC melhora performance até certo ponto
- não pode “roubar” RAM demais das VMs
Recomendação inicial:
- 32 GB RAM: 6–10 GB de ARC (comece em ~8 GB e ajuste medindo)
- 12 GB RAM: 2–4 GB de ARC (comece em ~3 GB)

---

## 2) Tipos de “RAID” no ZFS (vdevs)

### Disco único (lab)
- sem redundância
- rápido e simples
- exige backup/replicação bem feitos

### Mirror (RAID1)
- redundância (pode perder 1 disco por mirror)
- ótima leitura
- usado em produção SMB frequentemente

### RAIDZ-1 (similar ao RAID5)
- mínimo 3 discos
- tolera 1 falha
- boa eficiência de capacidade
- rebuild pode ser mais pesado

### RAIDZ-2 (similar ao RAID6)
- mínimo 4 discos
- tolera 2 falhas
- comum em storage corporativo

**Boas práticas:**
- não faça mirror com discos de tamanhos muito diferentes (desperdício)
- não use RAIDZ com menos discos que o mínimo
- planeje backup sempre (redundância ≠ backup)

---

## 3) Estratégia de storage do nosso lab

### Node1
- SSD 1TB em disco único (produção principal)

### Node2
- NVMe 2TB em disco único (produção secundária)
- SATA 1TB separado para **pool de backup**
Benefícios:
- separação física de função (prática empresarial)
- você aprende “produção vs backup”
- reduz risco de “um erro apagar tudo”

---

## 4) Rede do lab: LAN + Cluster sem VLAN

### LAN
- 192.168.68.0/24
- gateway: 192.168.68.1
- nodes: .70 e .71
- vmbr0 normalmente carrega o IP de gerência

### Cluster (corosync)
- 10.10.10.0/30
- sem gateway
- objetivo: tráfego de cluster separado da LAN (mesmo no mesmo switch)

**Por que /30?**
- só precisa de 2 IPs (um por nó)
- reduz broadcast e mantém simples

---

## 5) Proxmox 9: Repositórios e APT (deb822 `.sources`)

No PVE 9, o APT usa arquivos `.sources` (formato deb822) em:
- `/etc/apt/sources.list.d/`

Arquivos comuns:
- `debian.sources`
- `pve-enterprise.sources` (pago)
- `ceph.sources` (pode apontar enterprise)

### Quando não há subscription
- desativar enterprise com `Enabled: no`
- habilitar `pve-no-subscription`

**Por que isso importa?**
- evita erro 401
- mantém updates funcionando
- reduz duplicidade de fontes

---

## 6) Pós-instalação: boas práticas (segurança)

Recomendado em ambiente profissional:
- backups antes de alterar arquivos (sempre)
- remover fontes enterprise se não houver licença
- update/upgrade controlados, com log
- não executar `source <(curl ...)` como root (risco)
- SSH hardening somente após confirmar chaves:
  - `PermitRootLogin no`
  - `PasswordAuthentication no`
- firewall: limitar GUI (8006) por IP/rede quando possível

---

## 7) Subscription nag (mensagem na GUI)

A mensagem “You do not have a valid subscription…” é apenas UI.  
Remover é opcional, mas envolve patch em arquivo do toolkit web.

**Boas práticas adotadas:**
- sem hook no dpkg (mais seguro)
- patch mínimo e com backup
- se voltar após update: reaplicar manualmente (ou rodar script novamente)

---

## 8) Checklist rápido de validação pós-instalação

Em cada nó:
- `ip a` (IPs e bridges)
- `ip route` (default via 192.168.68.1)
- `zpool status` (ONLINE)
- `apt update` (sem 401)
- acesso GUI `https://IP:8006`

---

**FIM — DOC v3.0**
