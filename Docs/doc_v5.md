# Proxmox VE 9 Technical Documentation

Date: 2026-03-01

## ZFS Disk Provisioning

Command: qm set 100 --scsi0 local-zfs:32

Result: Creates ZFS volume rpool/data/vm-100-disk-0

ZFS characteristics: - Thin provisioning - Copy-on-write - Snapshot
support - Data integrity via checksums

## Boot Order

Command: qm set 100 --boot order="ide2;scsi0"

Explanation: - ide2 = CD-ROM - scsi0 = primary disk - Quotes required
due to shell semicolon interpretation

## VM Configuration File

Location: /etc/pve/qemu-server/100.conf

Cluster-synchronized via pmxcfs.

## Validation Commands

pvecm status pvesm status zfs list qm config 100 qm list

System ready for Ubuntu installation phase.
