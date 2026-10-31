# Changelog

All notable changes to this project. Format based on [Keep a Changelog](https://keepachangelog.com/), versioning based
on [SemVer](https://semver.org/).

## [Unreleased]

### Added
- `-BiosUuid`: SMBIOS UUID of the new VM (vSphere API, `uuid.action = keep`), refused if another VM still has it.
  Together with `-MacAddress` a rebuilt VM keeps the identity an offline LAS license depends on.
- `-ShowIdentity -VmName`: prints MACs and BIOS UUID of an existing VM as ready-made rebuild parameters.
- `-LasRequest`: offline LAS activation request via NITRO (`show ns licenseactivationdata`, optional
  `-UseHostname`), downloaded from `/nsconfig/license`; shows host name, identifier and build from the request.
- `-LasActivate -ActivationFile`: uploads the Citrix Cloud activation file and applies it
  (`apply ns laslicense -fixedBandwidth`); `-Reboot` saves, warm-reboots and shows the licensing mode.
- `-NsPinnedPublicKey` for the LAS modes (otherwise pinned on first contact with a warning).
- docs/vmware.md: "Offline LAS activation" and "Rebuild with the same identity" (what binds an activation to a VM,
  validated on 14.1 build 73.46 / 73.49).

## [1.0.0] - 2026-10-22

First release: unattended NetScaler VPX deployment on a standalone VMware ESXi host (no vCenter, no console clicks).
Validated on NetScaler 14.1 build 73.46 with E1000 and VMXNET3, 1 and 2 NICs.

### Added
- `vmware/Deploy-NsVpx.ps1` (PowerShell 7.2+, Windows, VMware PowerCLI), standalone - no other file needed:
  - OVF import from a datastore (thin), vCPU / memory, `-NicCount` and `-NicType E1000|Vmxnet3`, optional static
    MACs (`-MacAddress`, also outside the VMware manual range via `.vmx`)
  - first-boot **userdata ISO**: NSIP, mask, default route, host name, optional SNIP, DNS, NTP and extra CLI lines
    (`-ExtraConfig`); lines containing `password` are refused - no secrets in the ISO
  - management certificate key **pinned on first contact** (printed as `sha256//...`), forced nsroot password change
    via NITRO (first contact retried while NITRO starts), optional RPC node password, CallHome and MAC-based
    forwarding switched off (the userdata `disable` lines do not stick on 14.1), config saved
  - userdata ISO **removed automatically** after a successful run; kept for diagnosis on failure, with `-SkipNsroot`
    and with `-KeepIso` (the run prints the `-Cleanup` command)
  - `-EsxPinnedPublicKey`: ESXi host key checked before connecting (PowerCLI itself cannot pin)
  - `-WhatIf` dry run (checks, OVF present, userdata), `-ListOvf`, `-Cleanup`, `-InitNsroot` (password step only,
    against a running VPX)
  - all passwords prompted masked at the start; nothing on disk, in the ISO or on a command line
- `docs/vmware.md`: requirements, what the script does, usage, parameters, notes, screenshots, next steps
  (default SSL profile, HTTPS-only management, CA-signed management certificate)

[1.0.0]: https://github.com/bensplittgerber/netscaler-vpx-deploy/releases/tag/v1.0.0
