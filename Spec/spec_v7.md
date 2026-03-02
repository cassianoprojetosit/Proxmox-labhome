# SPEC -- Proxmox Lab Infrastructure (Professional Update)

Generated on: 2026-03-02

## VM Creation

Command: qm create 100 --name ubuntu-template-base --memory 4096 --cores
2 --cpu host --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci

Detailed Explanation: - qm create: Creates a new virtual machine
definition in Proxmox. - 100: Unique VM ID. - --memory 4096: Allocates
4GB RAM. - --cores 2: Assigns 2 virtual CPUs. - --cpu host: Enables CPU
passthrough for optimal performance. - --net0 virtio: Creates
high‑performance virtual NIC. - bridge=vmbr0: Connects VM to LAN
bridge. - --scsihw virtio-scsi-pci: Modern SCSI controller.

## Disk Creation

qm set 100 --scsi0 local-zfs:32

-   Creates 32GB thin-provisioned ZFS disk.
-   Stored under rpool/data.

## ISO Attachment

qm set 100 --ide2
local:iso/ubuntu-24.04.4-live-server-amd64.iso,media=cdrom qm set 100
--boot order="ide2;scsi0"

## ISO Removal

qm set 100 --delete ide2 qm set 100 --boot order=scsi0

## Guest Agent

qm set 100 --agent enabled=1 sudo apt install qemu-guest-agent sudo
systemctl start qemu-guest-agent

Important: VM must be rebooted after enabling agent on host.

## Template Hardening Commands

truncate -s 0 /etc/machine-id rm -f /var/lib/dbus/machine-id rm -f
/etc/ssh/ssh_host\_\* journalctl --rotate journalctl --vacuum-time=1s qm
template 100
