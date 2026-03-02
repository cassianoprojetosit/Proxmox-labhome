# Technical Documentation -- Template Preparation

Generated on: 2026-03-02

## Machine-ID Cleaning

Command: truncate -s 0 /etc/machine-id

Purpose: Clears unique Linux system identifier so clones generate new
identities.

## Removing SSH Host Keys

Command: rm -f /etc/ssh/ssh_host\_\*

Purpose: Prevents cloned systems from sharing identical SSH
fingerprints.

## Log Cleanup

journalctl --rotate journalctl --vacuum-time=1s

Purpose: Removes historical logs before template conversion.

## UUID Handling

Proxmox automatically regenerates: - smbios UUID - vmgenid

No manual action required.
