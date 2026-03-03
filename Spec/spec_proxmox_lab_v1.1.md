# SPEC -- Proxmox Lab Infrastructure (v1.1)

Updated: 2026-03-03

## Cluster
- pve-node1 → 192.168.68.70 / 10.10.10.1
- pve-node2 → 192.168.68.71 / 10.10.10.2
- Cluster Status: OK

---

## Template Base Ubuntu (VMID 100)

### VM Creation

qm create 100 \
  --name ubuntu-24-template-base \
  --memory 4096 \
  --cores 2 \
  --cpu host \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci

qm set 100 --scsi0 local-zfs:32
qm set 100 --ide2 local:iso/ubuntu-24.04.4-live-server-amd64.iso,media=cdrom
qm set 100 --boot order="ide2;scsi0"
qm set 100 --vga std

---

## Post Installation (Inside VM)

sudo apt update
sudo apt -y upgrade
sudo apt -y install openssh-server qemu-guest-agent curl wget vim net-tools htop

sudo systemctl enable --now ssh
sudo systemctl enable --now qemu-guest-agent

---

## Enable Guest Agent (Host)

qm set 100 --agent enabled=1
qm restart 100
qm agent 100 ping

Expected output:
agent responded

---

## SSH Host Key Regeneration (Official Standard)

File:
/etc/systemd/system/regenerate-ssh-hostkeys.service

[Unit]
Description=Regenerate SSH host keys at boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target

Activation:

sudo systemctl daemon-reload
sudo systemctl enable regenerate-ssh-hostkeys.service

---

## Clone Process

qm clone 100 101 --name vm-ubuntu-01 --full 1
qm start 101

Validation:

ls -l /etc/ssh/ssh_host_*
