# Proxmox Lab Specification (Updated)

Date: 2026-03-01

## Objective

Build and operate a Proxmox VE 9 cluster using ZFS and CLI-based VM
management.

## Infrastructure

Node1: - Hostname: pve-node1 - CPU: Ryzen 7 - RAM: 32GB - Disk: 1TB NVMe
(ZFS rpool) - LAN: 192.168.68.70/22 - Cluster: 10.10.10.1/24

Node2: - Hostname: pve-node2 - CPU: Ryzen 5 - RAM: 12GB - Disk: 2TB NVMe
(ZFS rpool) - Extra Disk: 1TB SATA (reserved for future use) - LAN:
192.168.68.71/22 - Cluster: 10.10.10.2/24

## Storage Layout (Node1)

rpool ├── ROOT/pve-1 ├── data └── var-lib-vz

VM disks stored as: rpool/data/vm-100-disk-0

ISO path: /var/lib/vz/template/iso

## VM Creation (CLI)

qm create 100 --name ubuntu-server --memory 4096 --cores 2 --cpu host
--net0 virtio,bridge=vmbr0 qm set 100 --scsihw virtio-scsi-pci qm set
100 --scsi0 local-zfs:32 qm set 100 --cdrom
local:iso/ubuntu-22.04.4-live-server-amd64.iso qm set 100 --boot
order="ide2;scsi0" qm start 100

## Current Status

-   Cluster operational (2 nodes, quorum OK)
-   Dedicated Corosync network working
-   ZFS storage validated
-   VM 100 successfully booted installer
