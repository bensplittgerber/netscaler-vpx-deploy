# netscaler-vpx-deploy

Unattended deployment of a NetScaler VPX on a hypervisor, without console clicks: import the image, set the
management network at first boot, change the forced nsroot password and switch off what a fresh VPX should not
run. Secrets are prompted masked and never written to disk, the ISO or a command line.

| Hypervisor | Script | Status |
|---|---|---|
| VMware ESXi (standalone host, no vCenter) | [`vmware/Deploy-NsVpx.ps1`](vmware/Deploy-NsVpx.ps1) | validated on 14.1 build 73.46 |
| KVM | - | planned |

## VMware ESXi

```powershell
Install-Module VCF.PowerCLI -Scope CurrentUser        # once

./vmware/Deploy-NsVpx.ps1 -EsxHost esx01.example.org -ListOvf
./vmware/Deploy-NsVpx.ps1 -EsxHost esx01.example.org -OvfPath '[datastore1] iso/NSVPX-ESX-14.1-xx.xx_nc_64.ovf' `
    -VmName ns01 -Datastore datastore1 -Nsip 192.0.2.10 -Gateway 192.0.2.1 -DnsServer 192.0.2.53 `
    -NtpServer 192.0.2.123 -NicType Vmxnet3 -NoProxy -WhatIf     # then the same line without -WhatIf
```

The userdata ISO is removed at the end of a successful run; after a failure it is kept for diagnosis and the run
prints the `-Cleanup` command.

What it does, all parameters and notes: [docs/vmware.md](docs/vmware.md).

In short:
- OVF import with PowerCLI (thin), vCPU / memory / NIC count and type (E1000 or VMXNET3), optional static MACs
- first-boot **userdata ISO** (NSIP, route, host name, SNIP, DNS, NTP, extra CLI lines) - no secrets in it
- management certificate key **pinned on first contact**, forced nsroot change via NITRO, CallHome and
  MAC-based forwarding switched off (the userdata `disable` lines do not stick on 14.1), config saved
- userdata ISO removed automatically after success (kept on failure, `-SkipNsroot`, `-KeepIso`)
- optional ESXi host key check (`-EsxPinnedPublicKey`), dry run (`-WhatIf`), manual ISO cleanup (`-Cleanup`)

## Requirements

Windows, PowerShell 7.2+, VMware PowerCLI, the VPX OVF package on a datastore of the host, HTTPS to the ESXi host and
to the new NSIP.

## License

[MIT](LICENSE)
