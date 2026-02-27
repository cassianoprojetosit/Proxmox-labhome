# SPEC v2.0

# Projeto Intensivo 30 Dias – Proxmox Profissional (Lab Completo)

Autor: Laboratório Técnico Proxmox Duração: 30 dias Carga diária
sugerida: 5 horas Objetivo: Dominar Proxmox do básico ao nível
profissional focado em SMB

------------------------------------------------------------------------

# 1. VISÃO GERAL DO PROJETO

Este documento descreve detalhadamente o plano de estudo e execução
prática para dominar Proxmox em 30 dias utilizando dois servidores
físicos.

O objetivo não é apenas aprender a ferramenta, mas:

-   Entender arquitetura de virtualização
-   Dominar ZFS na prática
-   Construir cluster funcional
-   Implementar replicação
-   Testar alta disponibilidade
-   Simular falhas reais
-   Documentar tudo como projeto profissional
-   Estar apto a oferecer serviços para empresas SMB

------------------------------------------------------------------------

# 2. INFRAESTRUTURA FÍSICA

## Node 1 (Principal)

-   Ryzen 7
-   32GB RAM
-   1TB SSD
-   2x Ethernet Função: Produção principal + cluster

## Node 2 (Secundário)

-   Ryzen 5
-   12GB RAM
-   2TB SSD
-   1x Ethernet Função: Replicação + Backup + Failover

------------------------------------------------------------------------

# 3. ARQUITETURA DE REDE DEFINITIVA

## LAN (Produção)

Faixa: 192.168.68.0/24 Gateway: 192.168.68.1

Node1: - 192.168.68.10

Node2: - 192.168.68.11

Gateway configurado apenas nesta rede.

## Cluster (Rede isolada logicamente)

Faixa: 10.10.10.0/30

Node1: - 10.10.10.1 (interface dedicada)

Node2: - 10.10.10.2 (IP secundário na mesma interface da LAN)

Sem gateway nesta rede.

------------------------------------------------------------------------

# 4. ESTRUTURA DO CURSO / LAB

O projeto está dividido em 4 fases.

------------------------------------------------------------------------

# FASE 1 – FUNDAÇÃO (Dias 1–7)

Objetivo: Dominar instalação e operação básica.

Conteúdo:

Dia 1–2 - Instalação Proxmox nos dois nodes - Configuração IP fixo -
Configuração ZFS RAID0 - Atualização do sistema - Verificação de
serviços

Dia 3 - Entendimento arquitetura Proxmox - KVM - LXC - Estrutura de
diretórios - Serviços principais

Dia 4 - Criação de VMs - Templates - Snapshots - Clones

Dia 5 - ZFS profundo - ARC - Compression - atime - Scrub - Benchmark
básico

Dia 6 - Backup manual - Restore completo - Teste de falha proposital

Dia 7 - Revisão geral - Documentação técnica da fundação

Resultado esperado: Operação independente do Proxmox.

------------------------------------------------------------------------

# FASE 2 – INFRA EMPRESARIAL (Dias 8–14)

Objetivo: Simular empresa real.

Criar ambiente fictício com:

-   VM Servidor de Arquivos
-   VM Aplicação
-   VM Banco de Dados
-   VM Firewall
-   VM Backup

Conteúdo:

-   Organização de storage
-   Boas práticas de alocação de recursos
-   Isolamento lógico de serviços
-   Monitoramento básico
-   Teste de carga leve

Resultado esperado: Ambiente empresarial funcional em um único nó.

------------------------------------------------------------------------

# FASE 3 – CLUSTER E ALTA DISPONIBILIDADE (Dias 15–23)

Objetivo: Transformar ambiente em estrutura profissional.

Conteúdo:

Dia 15–16 - Criação do cluster - Configuração corosync - Definição rede
cluster (10.10.10.x)

Dia 17 - Migração ao vivo de VM

Dia 18–19 - Configuração replicação ZFS

Dia 20 - Simulação falha Node 1

Dia 21 - Recuperação ambiente

Dia 22 - Ajustes finos de performance

Dia 23 - Documentação de arquitetura de cluster

Resultado esperado: Cluster funcional com replicação testada.

------------------------------------------------------------------------

# FASE 4 – TRANSFORMAÇÃO EM SERVIÇO (Dias 24–30)

Objetivo: Converter conhecimento técnico em serviço vendável.

Conteúdo:

Dia 24 - Documentação final da arquitetura

Dia 25 - Diagrama de rede

Dia 26 - Comparação técnica com VMware

Dia 27 - Estratégia de migração

Dia 28 - Cálculo de economia real

Dia 29 - Modelo de proposta técnica

Dia 30 - Simulação de apresentação para cliente

Resultado esperado: Capacidade de vender implementação Proxmox para SMB.

------------------------------------------------------------------------

# 5. MÉTRICAS DE SUCESSO

Ao final dos 30 dias o aluno deve ser capaz de:

-   Instalar Proxmox sem auxílio
-   Configurar ZFS corretamente
-   Criar cluster funcional
-   Explicar quorum
-   Simular falha e recuperar
-   Documentar arquitetura
-   Justificar decisões técnicas

------------------------------------------------------------------------

# 6. REGRAS DO PROJETO

-   Estudar 5h por dia
-   Documentar diariamente
-   Não iniciar projetos paralelos
-   Atualizar esta SPEC conforme evolução
-   Manter disciplina de execução

------------------------------------------------------------------------

# 7. RESULTADO FINAL ESPERADO

Perfil alcançado:

Administrador de Virtualização com foco em pequenas e médias empresas,
capaz de implementar, otimizar e vender soluções baseadas em Proxmox.

------------------------------------------------------------------------

FIM DA SPEC v2.0
