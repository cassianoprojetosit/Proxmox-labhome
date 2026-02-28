# Proxmox VE 9 Cluster Technical Documentation

Date: 2026-02-28

## APT deb822 Format

Proxmox 9 uses .sources files instead of .list.

Key directory: /etc/apt/sources.list.d/

## Secondary IP Logic

post-up ip addr add 10.10.10.X/24 dev vmbr0 post-down ip addr del
10.10.10.X/24 dev vmbr0

This adds a secondary IP to the same bridge interface.

## Corosync Configuration

File: /etc/pve/corosync.conf

nodelist { node { name: pve-node1 ring0_addr: 10.10.10.1 } node { name:
pve-node2 ring0_addr: 10.10.10.2 } }

## Quorum

2-node cluster: Expected votes: 2 Quorum: 2

If one node fails → cluster loses quorum.

## Validation Commands

pvecm status ip addr show vmbr0 cat /etc/pve/corosync.conf
