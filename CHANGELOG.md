# Changelog

All notable changes to this project. Format based on [Keep a Changelog](https://keepachangelog.com/), versioning based
on [SemVer](https://semver.org/).

## [Unreleased]

### Added
- `vmware/Deploy-NsVpx.ps1`: NetScaler VPX on a standalone ESXi host with PowerCLI - OVF import, first-boot userdata
  ISO, management key pinned on first contact, forced nsroot change via NITRO, CallHome / MBF off, `-Cleanup`,
  `-ListOvf`, `-InitNsroot`, `-WhatIf`, `-NicType E1000|Vmxnet3`, `-MacAddress`, `-EsxPinnedPublicKey`.
  Standalone (built-in pinned NITRO client). Validated on 14.1 build 73.46 with E1000 and VMXNET3, 2 NICs.
