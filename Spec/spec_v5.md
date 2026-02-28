# Proxmox Lab Specification (Updated)

Date: 2026-02-28

## 1. Lab Objective

Build a professional Proxmox VE 9 cluster from scratch using
enterprise-grade practices.

## 2. Infrastructure

### Node1

Hostname: pve-node1 LAN IP: 192.168.68.70/22 Cluster IP: 10.10.10.1/24

### Node2

Hostname: pve-node2 LAN IP: 192.168.68.71/22 Cluster IP: 10.10.10.2/24

## 3. Repository Configuration (Manual)

Removed: rm /etc/apt/sources.list.d/pve-enterprise.sources rm
/etc/apt/sources.list.d/ceph.sources

Created: /etc/apt/sources.list.d/pve-no-subscription.sources

Types: deb URIs: http://download.proxmox.com/debian/pve Suites: trixie
Components: pve-no-subscription Signed-By:
/usr/share/keyrings/proxmox-archive-keyring.gpg

System update: apt update apt full-upgrade reboot

## 4. Dedicated Cluster Network

In /etc/network/interfaces

Node1: post-up ip addr add 10.10.10.1/24 dev vmbr0 post-down ip addr del
10.10.10.1/24 dev vmbr0

Node2: post-up ip addr add 10.10.10.2/24 dev vmbr0 post-down ip addr del
10.10.10.2/24 dev vmbr0

Validation: ip addr show vmbr0 ping 10.10.10.X

## 5. Cluster Creation

On Node1: pvecm create cluster-lab --link0 10.10.10.1

Check: pvecm status

## 6. Join Node2

On Node2: pvecm add pve-node1

Check: pvecm status

## 7. Corosync Correction

Edited /etc/pve/corosync.conf to ensure:

ring0_addr: 10.10.10.1 ring0_addr: 10.10.10.2

Restart: systemctl restart corosync

## 8. Final State

-   2 nodes active
-   Quorum operational
-   Dedicated cluster network
-   Central dashboard working

Next: - VM creation - Migration testing - HA study
