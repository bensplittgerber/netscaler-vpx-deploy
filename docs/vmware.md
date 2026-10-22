# Deploying a VPX on ESXi

`vmware/Deploy-NsVpx.ps1` puts a new NetScaler VPX on a **standalone ESXi host** (no vCenter, no console session):
OVF import, network settings at first boot, forced nsroot password change. After that the VPX is ready for its
configuration (CLI, GUI or NITRO tooling). The script is standalone: no other file of this repo is needed.

## Requirements

- Windows with PowerShell 7.2+ (the userdata ISO is built with the Windows IMAPI2 API; `-InitNsroot` alone also runs
  on Linux/macOS).
- VMware PowerCLI, once per user: `Install-Module VCF.PowerCLI -Scope CurrentUser` (older name: `VMware.PowerCLI`).
- The VPX OVF package for ESX (`NSVPX-ESX-<build>_nc_64.ovf` + `.mf` + disk) unpacked on a datastore of the host.
- HTTPS/443 from this machine to the new NSIP, and the ESXi host's HTTPS API.
- An ESXi account that may create VMs (prompted; root on a lab host).

## What it does

1. Copies the OVF package from the datastore to a temp folder and imports it (`Import-VApp`, thin disks);
   sets vCPU, memory, NIC count, port group and optional static MAC addresses.
2. Builds a **preboot userdata ISO** (NetScaler: "Apply NetScaler VPX configurations at the first boot of the
   NetScaler appliance on VMware ESX") with NSIP + mask, default route, host name, optional SNIP, DNS and NTP
   servers and the lines of `-ExtraConfig`, copies it into the VM folder and attaches it as CD drive. The ISO holds
   **no secrets**: `-ExtraConfig` lines containing `password` are refused.
3. Powers the VM on and waits up to 15 minutes for 443 on the NSIP.
4. Reads the new VPX's self-signed management certificate key and **pins it on first contact** (printed as
   `sha256//...`), logs in with the image's default nsroot password and a new one (the forced first-login
   change), optionally sets the RPC node password, disables `-DisableFeature` (default `CH`) and `-DisableMode`
   (default `MBF`) and saves the config.
5. Removes the userdata ISO (eject, delete from the datastore) once step 4 has succeeded: the NITRO login proves the
   first boot applied it. The ISO is **kept** for diagnosis if anything fails (443 timeout, NITRO error), with
   `-SkipNsroot` (first boot not confirmed) and with `-KeepIso`; the run then prints the `-Cleanup` command.

All passwords are prompted masked at the start (ESXi login, image default nsroot password, new nsroot password
twice, RPC password with `-SetRpcPassword`), so the run is unattended afterwards. They stay in memory; nothing goes
into the ISO, a file or a command line.

## Usage

```powershell
# where is the OVF?
./vmware/Deploy-NsVpx.ps1 -EsxHost esx01.example.org -ListOvf

# dry run: checks and the userdata, no prompts except the ESXi login, no changes
./vmware/Deploy-NsVpx.ps1 -EsxHost esx01.example.org -OvfPath '[datastore1] iso/NSVPX-ESX-14.1-xx.xx_nc_64.ovf' `
    -VmName ns01 -Datastore datastore1 -Nsip 192.0.2.10 -Gateway 192.0.2.1 -Snip 192.0.2.11 `
    -DnsServer 192.0.2.53 -NtpServer 192.0.2.123 -EsxPinnedPublicKey 'sha256//...' -NoProxy -WhatIf

# deploy (same line without -WhatIf); removes the userdata ISO at the end

# only after a failed run, -SkipNsroot or -KeepIso: eject + delete the userdata ISO (VM may keep running)
./vmware/Deploy-NsVpx.ps1 -EsxHost esx01.example.org -VmName ns01 -Datastore datastore1 -Cleanup
```

The deploy prints the management key pin (`sha256//...`, same format as `curl --pinnedpubkey`); NITRO tools that
support key pinning can use it until the management certificate is replaced.

## Next steps

1. Fresh 14.1 VPX: enable the default SSL profile before creating SSL vservers
   (`set ssl parameter -defaultProfile ENABLED`, cannot be undone) - otherwise new vservers allow SSLv3/TLS 1.0/1.1.
2. Management access only over HTTPS: `set ns ip <NSIP> -gui SECUREONLY -telnet DISABLED -ftp DISABLED`.
3. Management certificate: replace the self-signed one with a CA-signed certificate that renews itself, e.g. with
   [netscaler-acme](https://github.com/bensplittgerber/netscaler-acme) (ACME, binds it to the management services).
   Afterwards trust the CA instead of the pin.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-EsxHost` | - | ESXi host name or IP |
| `-EsxPinnedPublicKey` | none (warning) | `sha256//...` of the ESXi host key; a mismatch stops the run (see Notes) |
| `-OvfPath` | - | `'[datastore] folder/file.ovf'` as printed by `-ListOvf` |
| `-VmName` | - | VM name; also the NetScaler host name unless `-HostName` is set |
| `-Datastore` | - | datastore for the VM and the userdata ISO |
| `-Network` | `VM Network` | port group for all NICs |
| `-Nsip`, `-Netmask`, `-Gateway` | -, `255.255.255.0`, - | management address and default route |
| `-Snip` | none | SNIP at first boot; leave empty for an HA secondary (the primary's SNIP floats over) |
| `-DnsServer`, `-NtpServer` | none | one or more; NTP also enables `ntp sync` |
| `-ExtraConfig` | none | `.cli` file(s) with more first-boot lines (`enable ns feature ...`, modes); `#` = comment |
| `-ExpectBuild` | none | warn if the OVF name does not contain this build (HA needs the same build on both nodes) |
| `-NumCpu`, `-MemoryGB`, `-NicCount` | 2, 2, 1 | VM size; NICs 0/1, 1/1, 1/2, ... all on `-Network` |
| `-NicType` | as in the OVF (E1000) | `Vmxnet3` or `E1000` for all NICs (VMXNET3: paravirtual, less host CPU) |
| `-MacAddress` | ESXi generated | one MAC per NIC, e.g. to keep the MAC of a rebuilt VM (DHCP, firewall, NAT entries) |
| `-SkipNsroot` | off | no password change; do it at the first login or later with `-InitNsroot` (ISO is kept) |
| `-KeepIso` | off | keep the userdata ISO after a successful run (remove it later with `-Cleanup`) |
| `-SetRpcPassword` | off | also prompt for an RPC node password (must be the same on both HA nodes) |
| `-DisableFeature`, `-DisableMode` | `CH`, `MBF` | switched off after boot; `@()` leaves them as they are |
| `-NoProxy` | off | NITRO calls bypass the system proxy |
| `-WhatIf` | off | dry run: checks + userdata only |

Other modes: `-ListOvf` (OVFs on all datastores), `-Cleanup` (userdata ISO off the VM and the datastore, for the
cases where the deploy kept it),
`-InitNsroot -Nsip ...` (only step 4 against a running VPX, asks for the current and an optional new password).

## Notes

- **Pin on first contact**: the key is read from the network without any trust anchor. That is acceptable for a
  freshly deployed VM on a management LAN; compare it with the VM console (`show ssl certKey ns-server-certificate`)
  if the path is not trusted. Replace the management certificate later (see Next steps).
- `disable ns feature` / `disable ns mode` lines in the userdata do not stick on 14.1 (CH and MBF are on again
  after the first boot); `enable` lines work. That is why step 4 disables them via NITRO.
- An existing VM with the same name stops the run. For a rebuild power off and remove the old VM first; pass its
  MAC with `-MacAddress` if something depends on it. MACs outside the VMware manual range (`00:50:56:00-3f:..`)
  are written into the `.vmx` directly (`checkMACAddress = FALSE`) and the VM is re-registered.
- **ESXi host certificate**: PowerCLI cannot pin keys, so it runs with `InvalidCertificateAction Ignore` (current
  session only). Pass `-EsxPinnedPublicKey` and the script compares the host key on its own TLS handshake right
  before `Connect-VIServer`; a mismatch stops the run, without it you get a warning. Read the value on the host
  (ESXi shell/SSH), not over the network you want to check:
  ```sh
  openssl x509 -in /etc/vmware/ssl/rui.crt -noout -pubkey | openssl pkey -pubin -outform der |
    openssl dgst -sha256 -binary | openssl base64      # prefix the output with sha256//
  ```
  The value changes when the host certificate is renewed.
- The ESXi banner "configured guest OS (FreeBSD (64-bit)) ... does not match ... FreeBSD 11 (64-bit)" is cosmetic:
  the OVF's hardware version (ESXi 6.5, vmx-13) has no FreeBSD 11 entry, so the script leaves the guest OS as is.
- IDE CD drives cannot be removed from a running VM, so the ISO is ejected and the empty drive stays. If ESXi asks
  to override the guest's tray lock, the script answers Yes. If the automatic removal fails, the VPX is still ready:
  the run warns and prints the `-Cleanup` command.
- Snapshots: take them after the ISO is gone, otherwise a revert asks for the deleted ISO.
