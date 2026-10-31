#Requires -Version 7.2
<#
.SYNOPSIS
    Deploys a NetScaler VPX from an OVF on a standalone ESXi host (no vCenter, no console), first-boot config
    through a userdata ISO, then the forced nsroot password change via NITRO.

.DESCRIPTION
    Deploy (-OvfPath):
      1. copies the OVF package (.ovf, .mf, disks) from the datastore to a temp folder and imports it with PowerCLI
         Import-VApp (thin), sets vCPU / memory / NICs / port group, optional static MAC(s) and BIOS UUID
      2. builds a preboot userdata ISO (NSIP, mask, default route, host name, optional SNIP, DNS, NTP, -ExtraConfig
         lines - never secrets), copies it to the VM folder and attaches it as CD
         (NetScaler docs: "Apply NetScaler VPX configurations at the first boot ... on VMware ESX")
      3. powers on and waits until the NSIP answers on 443
      4. pins the new VPX's self-signed management key on first contact (printed - use it for the next scripts),
         logs in with the image's default password + new_password (the forced first-login change), optional RPC
         node password, disables -DisableFeature / -DisableMode (default: CH, MBF - the same lines in the
         userdata do not stick), save ns config
      5. removes the userdata ISO (eject + delete from the datastore) - only after step 4 succeeded. Kept on any
         failure, with -SkipNsroot and with -KeepIso; the run then prints the -Cleanup command.
    -Cleanup: ejects the userdata ISO (or removes the CD drive if the VM is off) and deletes it from the datastore.
    -InitNsroot: step 4 only, against a running VPX. -ListOvf: lists OVFs on all datastores.
    -ShowIdentity: prints MAC(s) and BIOS UUID of an existing VM as -MacAddress / -BiosUuid for its rebuild.
    -LasRequest: offline LAS activation request on a running VPX (NITRO), downloaded as <name>_activation_request.tgz.
    -LasActivate: uploads the activation file from Citrix Cloud to /nsconfig/license and applies it (-Reboot: save,
      warm reboot, show the licensing mode).
    An offline LAS activation only works on the VPX that created the request. A rebuild keeps it only with the same
    MAC on 0/1, the same BIOS UUID and a restored full system backup (docs/vmware.md, "Rebuild with the same
    identity").

    Prompts (masked, all at the start so the run is unattended): ESXi login; nsroot default password of the image,
    new nsroot password (twice); RPC password with -SetRpcPassword. Passwords stay in memory (SecureString, plain only
    inside the NITRO request body): nothing in the ISO, on disk or on a command line.
    ESXi host certificate: PowerCLI cannot pin, so it runs with InvalidCertificateAction Ignore (this session only).
    With -EsxPinnedPublicKey the host's key is compared right before connecting and a mismatch stops the run.

    Windows only (the ISO is built with the Windows IMAPI2 API). Needs VMware PowerCLI:
    Install-Module VCF.PowerCLI -Scope CurrentUser  (older name: VMware.PowerCLI)

.EXAMPLE
    ./Deploy-NsVpx.ps1 -EsxHost esx01.example.org -ListOvf
.EXAMPLE
    ./Deploy-NsVpx.ps1 -EsxHost esx01.example.org -OvfPath '[datastore1] iso/NSVPX-ESX-14.1-xx.xx_nc_64.ovf' `
        -VmName ns01 -Datastore datastore1 -Nsip 192.0.2.10 -Gateway 192.0.2.1 -DnsServer 192.0.2.53 `
        -NtpServer 192.0.2.123 -Snip 192.0.2.11 -NoProxy -WhatIf
.EXAMPLE
    ./Deploy-NsVpx.ps1 -EsxHost esx01.example.org -VmName ns01 -Datastore datastore1 -Cleanup
.EXAMPLE
    ./Deploy-NsVpx.ps1 -InitNsroot -Nsip 192.0.2.10 -NoProxy
.EXAMPLE
    ./Deploy-NsVpx.ps1 -EsxHost esx01.example.org -VmName ns01 -ShowIdentity
.EXAMPLE
    ./Deploy-NsVpx.ps1 -LasRequest -Nsip 192.0.2.10 -NsPinnedPublicKey 'sha256//...' -OutDir . -NoProxy
.EXAMPLE
    ./Deploy-NsVpx.ps1 -LasActivate -Nsip 192.0.2.10 -ActivationFile ./NS_<id>_activation.blob.tgz -Reboot -NoProxy
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Deploy')]
param(
    [Parameter(ParameterSetName = 'List', Mandatory)][switch]$ListOvf,
    [Parameter(ParameterSetName = 'Deploy', Mandatory)][string]$OvfPath,   # '[datastore] folder/file.ovf'
    [Parameter(ParameterSetName = 'Cleanup', Mandatory)][switch]$Cleanup,
    [Parameter(ParameterSetName = 'InitNsroot', Mandatory)][switch]$InitNsroot,
    [Parameter(ParameterSetName = 'Identity', Mandatory)][switch]$ShowIdentity,
    [Parameter(ParameterSetName = 'LasRequest', Mandatory)][switch]$LasRequest,
    [Parameter(ParameterSetName = 'LasActivate', Mandatory)][switch]$LasActivate,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [Parameter(ParameterSetName = 'Deploy', Mandatory)]
    [Parameter(ParameterSetName = 'Cleanup', Mandatory)]
    [Parameter(ParameterSetName = 'Identity', Mandatory)][string]$EsxHost,
    # 'sha256//<base64 SPKI hash>' of the ESXi host certificate key (see docs/vmware.md). Empty: not checked.
    [Parameter(ParameterSetName = 'List')]
    [Parameter(ParameterSetName = 'Deploy')]
    [Parameter(ParameterSetName = 'Cleanup')]
    [Parameter(ParameterSetName = 'Identity')][string]$EsxPinnedPublicKey,
    [Parameter(ParameterSetName = 'Deploy', Mandatory)]
    [Parameter(ParameterSetName = 'Cleanup', Mandatory)]
    [Parameter(ParameterSetName = 'Identity', Mandatory)][string]$VmName,
    # datastore for the VM and the userdata ISO (the OVF may sit on another one)
    [Parameter(ParameterSetName = 'Deploy', Mandatory)]
    [Parameter(ParameterSetName = 'Cleanup', Mandatory)][string]$Datastore,
    [Parameter(ParameterSetName = 'Deploy')][string]$Network = 'VM Network',

    [Parameter(ParameterSetName = 'Deploy', Mandatory)]
    [Parameter(ParameterSetName = 'InitNsroot', Mandatory)]
    [Parameter(ParameterSetName = 'LasRequest', Mandatory)]
    [Parameter(ParameterSetName = 'LasActivate', Mandatory)][string]$Nsip,
    [Parameter(ParameterSetName = 'Deploy')][string]$Netmask = '255.255.255.0',
    [Parameter(ParameterSetName = 'Deploy', Mandatory)][string]$Gateway,
    [Parameter(ParameterSetName = 'Deploy')][string]$HostName,             # empty: -VmName
    [Parameter(ParameterSetName = 'Deploy')][string]$Snip,                 # empty: no SNIP (e.g. HA secondary)
    [Parameter(ParameterSetName = 'Deploy')][string[]]$DnsServer,
    [Parameter(ParameterSetName = 'Deploy')][string[]]$NtpServer,          # set: NTP server(s) + enable ntp sync
    # .cli file(s) with extra first-boot lines (features, modes, ...). '#' comments and blank lines are ignored.
    # No secrets: lines containing 'password' are refused.
    [Parameter(ParameterSetName = 'Deploy')][string[]]$ExtraConfig,
    # warn if the OVF file name does not contain this build (e.g. '14.1-xx.xx' - HA needs the same build on both nodes)
    [Parameter(ParameterSetName = 'Deploy')][string]$ExpectBuild,
    [Parameter(ParameterSetName = 'Deploy')][int]$NumCpu = 2,
    [Parameter(ParameterSetName = 'Deploy')][int]$MemoryGB = 2,
    [Parameter(ParameterSetName = 'Deploy')][ValidateRange(1, 4)][int]$NicCount = 1,   # all on -Network (VPX: 0/1, 1/1, 1/2, ...)
    # adapter type for all NICs; empty: as in the OVF (14.1 ESX OVF: E1000)
    [Parameter(ParameterSetName = 'Deploy')][ValidateSet('E1000', 'Vmxnet3')][string]$NicType,
    # optional static MAC per NIC, in order (rebuild with the MAC the firewall / DHCP / NAT entries expect).
    # Empty: ESXi generates them.
    [Parameter(ParameterSetName = 'Deploy')][string[]]$MacAddress,
    # optional SMBIOS UUID of the VM (VMware 'uuid.bios'), e.g. kept from the old VM (-ShowIdentity). Formats:
    # '56 4d xx .. xx-xx .. xx' (.vmx), '564dxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' or 32 hex digits. Empty: ESXi generates it.
    [Parameter(ParameterSetName = 'Deploy')][string]$BiosUuid,

    [Parameter(ParameterSetName = 'Deploy')][switch]$SkipNsroot,           # leave the password change to the first login
    [Parameter(ParameterSetName = 'Deploy')][switch]$KeepIso,              # do not remove the userdata ISO after a successful run
    [Parameter(ParameterSetName = 'Deploy')]
    [Parameter(ParameterSetName = 'InitNsroot')][switch]$SetRpcPassword,   # HA: the same RPC password on both nodes
    [Parameter(ParameterSetName = 'Deploy')]
    [Parameter(ParameterSetName = 'InitNsroot')][string[]]$DisableFeature = @('CH'),   # @() = leave as is
    [Parameter(ParameterSetName = 'Deploy')]
    [Parameter(ParameterSetName = 'InitNsroot')][string[]]$DisableMode = @('MBF'),     # @() = leave as is
    [Parameter(ParameterSetName = 'Deploy')]
    [Parameter(ParameterSetName = 'InitNsroot')]
    [Parameter(ParameterSetName = 'LasRequest')]
    [Parameter(ParameterSetName = 'LasActivate')][switch]$NoProxy,

    # LAS modes: 'sha256//...' of the VPX management certificate key (printed by the deploy). Empty: pinned on first
    # contact (with a warning).
    [Parameter(ParameterSetName = 'LasRequest')]
    [Parameter(ParameterSetName = 'LasActivate')][string]$NsPinnedPublicKey,
    # -LasRequest: identify the VPX by its host name instead of the system identifier (GUI toggle "Use hostname").
    # The request still carries the MAC-based identifier.
    [Parameter(ParameterSetName = 'LasRequest')][switch]$UseHostname,
    [Parameter(ParameterSetName = 'LasRequest')][string]$OutDir = '.',
    # -LasActivate: the activation file from Citrix Cloud (NS_<id or host name>_activation.blob.tgz)
    [Parameter(ParameterSetName = 'LasActivate', Mandatory)][string]$ActivationFile,
    # -LasActivate: save the config, warm reboot (the licensing mode changes only after a reboot), show the result
    [Parameter(ParameterSetName = 'LasActivate')][switch]$Reboot
)
$ErrorActionPreference = 'Stop'
# -WhatIf = dry run of the whole deployment (shows the userdata), not passed down to PowerCLI / PSDrive cmdlets
$dryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false
if (-not $HostName) { $HostName = $VmName }

# --- minimal NITRO client, always pinned -----------------------------------------------------------------------------
# The TLS callback runs on .NET worker threads, where PowerShell script blocks cannot run -> small C# validator.
# Own type name, so it does not clash with other NITRO tooling loaded in the same session.
if (-not ('NsVpxDeploy.Pin' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net.Http;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
namespace NsVpxDeploy {
    public static class Pin {
        public static string Spki(X509Certificate2 cert) {
            using (var sha = SHA256.Create())
                return "sha256//" + Convert.ToBase64String(sha.ComputeHash(cert.PublicKey.ExportSubjectPublicKeyInfo()));
        }
        public static HttpClient NewClient(string pin, bool noProxy) {
            var h = new HttpClientHandler();
            h.UseProxy = !noProxy;
            h.UseCookies = false;
            h.ServerCertificateCustomValidationCallback = (msg, cert, chain, errors) =>
                cert != null && string.Equals(Spki(cert), pin, StringComparison.Ordinal);
            return new HttpClient(h) { Timeout = TimeSpan.FromSeconds(120) };
        }
    }
}
'@
}

function Get-KeyPin([string]$Server, [int]$Port = 443) {
    # 'sha256//<base64 SPKI hash>' of the presented certificate key (curl --pinnedpubkey format), read WITHOUT trusting it
    $tcp = [System.Net.Sockets.TcpClient]::new($Server, $Port)
    try {
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($Server)
        [NsVpxDeploy.Pin]::Spki([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate))
    }
    finally { $tcp.Dispose() }
}

function Invoke-NsNitro([hashtable]$Session, [string]$Method, [string]$Resource, [string]$Query, $Body) {
    # one NITRO call over the pinned client; TLS/connection errors throw, NITRO errors come back in ErrorCode/Message
    $uri = "$($Session.Base)/$Resource$(if ($Query) { "?$Query" })"
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $uri)
    if ($Session.Cookie) { [void]$req.Headers.TryAddWithoutValidation('Cookie', $Session.Cookie) }
    if ($null -ne $Body) {
        $req.Content = [System.Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 10 -Compress), [Text.Encoding]::UTF8)
        # NITRO rejects 'application/json; charset=utf-8'
        $req.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
    }
    $res  = $Session.Client.SendAsync($req).GetAwaiter().GetResult()
    $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $data = if ($text) { try { $text | ConvertFrom-Json } catch { $null } }
    $code = if ($null -ne $data.errorcode) { [int]$data.errorcode } elseif ([int]$res.StatusCode -ge 400) { -1 } else { 0 }
    [pscustomobject]@{ Http = [int]$res.StatusCode; ErrorCode = $code; Message = $data.message; Data = $data }
}

function Connect-NsNitro([hashtable]$Session, [securestring]$Password) {
    $r = Invoke-NsNitro -Session $Session -Method POST -Resource 'login' -Body @{ login = @{
        username = 'nsroot'; password = [Net.NetworkCredential]::new('', $Password).Password } }
    if ($r.ErrorCode -ne 0 -or -not $r.Data.sessionid) { throw "NITRO login as nsroot failed: $($r.ErrorCode) $($r.Message)" }
    $Session.Cookie = "NITRO_AUTH_TOKEN=$($r.Data.sessionid)"
}

function Disconnect-NsNitro([hashtable]$Session) {
    if (-not $Session.Cookie) { return }
    try { [void](Invoke-NsNitro -Session $Session -Method POST -Resource 'logout' -Body @{ logout = @{} }) } catch { }
    $Session.Cookie = $null
    Write-Host 'Logged out.'
}

function Write-Step([string]$Label, $Result) {
    if ($Result.ErrorCode -eq 0) { Write-Host "  [OK]      $Label" -ForegroundColor Green; return }
    Write-Host "  [FAILED]  $Label  -> $($Result.ErrorCode): $($Result.Message)" -ForegroundColor Red
    throw "Stopping at failed step: $Label"
}

if ($MacAddress) {
    $MacAddress = @($MacAddress | ForEach-Object { $_.ToLower() -replace '-', ':' })
    foreach ($m in $MacAddress) { if ($m -notmatch '^([0-9a-f]{2}:){5}[0-9a-f]{2}$') { throw "-MacAddress '$m' is not a MAC address." } }
    if ($MacAddress.Count -ne $NicCount) { throw "$($MacAddress.Count) MAC(s) for $NicCount NIC(s) - one MAC per NIC." }
}
if ($BiosUuid) {
    # any of the three spellings -> 8-4-4-4-12 (vSphere API format of config.uuid)
    $hex = ($BiosUuid -replace '[\s-]', '').ToLower()
    if ($hex -notmatch '^[0-9a-f]{32}$') { throw "-BiosUuid '$BiosUuid' is not a UUID (32 hex digits)." }
    $BiosUuid = '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20)
}

function Set-VmStaticMac($Vm, [string[]]$Mac, [string]$WorkDir) {
    # 00:50:56:00-3f:xx:xx = VMware manual range -> API. Anything else (e.g. 00:0c:29 = auto-generated, kept from an
    # old VM) is refused by the API -> .vmx edit with checkMACAddress FALSE, then re-register the VM (powered off here).
    # NIC n = 'Network adapter n' = ethernet(n-1) in the .vmx.
    $nics = @(Get-NetworkAdapter -VM $Vm | Sort-Object Name)
    if (-not ($Mac | Where-Object { $_ -notmatch '^00:50:56:[0-3][0-9a-f]:' })) {
        for ($i = 0; $i -lt $Mac.Count; $i++) { $nics[$i] | Set-NetworkAdapter -MacAddress $Mac[$i] -Confirm:$false | Out-Null }
        return $Vm
    }
    $vmxPath = $Vm.ExtensionData.Config.Files.VmPathName              # '[datastore] ns01/ns01.vmx'
    if ($vmxPath -notmatch '^\[(?<ds>[^\]]+)\]\s*(?<p>.+)$') { throw "unexpected vmx path $vmxPath" }
    $rel = $Matches.p -replace '/', '\'
    $vmDs = Get-Datastore $Matches.ds
    New-PSDrive -Name vmx -PSProvider VimDatastore -Root '\' -Location $vmDs | Out-Null
    try {
        $local = Join-Path $WorkDir (Split-Path -Leaf $rel)
        Copy-DatastoreItem "vmx:\$rel" $local
        $lines = Get-Content $local
        for ($i = 0; $i -lt $Mac.Count; $i++) {
            $e = "ethernet$i"
            if (-not ($lines -match "^$e\.present\s*=\s*`"TRUE`"")) { throw "no $e in $vmxPath - cannot set MAC $($Mac[$i])" }
            $lines = @($lines | Where-Object { $_ -notmatch "^$e\.(addressType|address|generatedAddress|generatedAddressOffset|checkMACAddress)\s*=" })
            $lines += "$e.addressType = `"static`"", "$e.address = `"$($Mac[$i])`"", "$e.checkMACAddress = `"FALSE`""
        }
        [IO.File]::WriteAllText($local, ($lines -join "`n") + "`n", [Text.Encoding]::ASCII)
        Copy-DatastoreItem $local "vmx:\$(Split-Path -Parent $rel)\" -Force
    }
    finally { Remove-PSDrive vmx }
    $vmHost = $Vm.VMHost
    Remove-VM $Vm -Confirm:$false                                      # unregister only, files stay
    New-VM -VMFilePath $vmxPath -VMHost $vmHost
}

function Set-VmBiosUuid($Vm, [string]$Uuid) {
    # SMBIOS UUID (uuid.bios) through the vSphere API. uuid.action = keep: no "moved or copied?" question at power-on
    # (uuid.location no longer matches), and ESXi does not generate a new UUID.
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.Uuid = $Uuid
    $spec.ExtraConfig = @(New-Object VMware.Vim.OptionValue -Property @{ Key = 'uuid.action'; Value = 'keep' })
    $Vm.ExtensionData.ReconfigVM($spec)
    $Vm = Get-VM -Id $Vm.Id
    if ($Vm.ExtensionData.Config.Uuid -ne $Uuid) { throw "BIOS UUID is $($Vm.ExtensionData.Config.Uuid), expected $Uuid." }
    Write-Host "BIOS UUID: $Uuid" -ForegroundColor DarkGray
    $Vm
}

function Format-VmxUuid([string]$Uuid) {
    # 8-4-4-4-12 -> '56 4d .. ..-.. ..' as in the .vmx (uuid.bios)
    $h = $Uuid -replace '-', ''
    $b = for ($i = 0; $i -lt 32; $i += 2) { $h.Substring($i, 2) }
    ($b[0..7] -join ' ') + '-' + ($b[8..15] -join ' ')
}

function New-UserdataIso([string]$Dir, [string]$Out) {
    # ISO 9660 + Joliet via the Windows IMAPI2 COM API (no mkisofs/oscdimg needed)
    if (-not ('IsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class IsoWriter {
    public static void Write(string path, object stream) {
        IStream s = (IStream)stream;
        STATSTG st; s.Stat(out st, 1);
        byte[] buf = new byte[65536];
        IntPtr pRead = Marshal.AllocHGlobal(4);
        try {
            using (FileStream fs = File.Create(path)) {
                long left = st.cbSize;
                while (left > 0) {
                    s.Read(buf, buf.Length, pRead);
                    int n = Marshal.ReadInt32(pRead);
                    if (n <= 0) break;
                    fs.Write(buf, 0, n); left -= n;
                }
            }
        } finally { Marshal.FreeHGlobal(pRead); }
    }
}
'@
    }
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
    $fsi.VolumeName = 'USERDATA'
    $fsi.Root.AddTree($Dir, $false)
    [IsoWriter]::Write($Out, $fsi.CreateResultImage().ImageStream)
}

function Read-Secret([string]$Prompt, [switch]$Confirm, [switch]$AllowEmpty) {
    while ($true) {
        $a = Read-Host $Prompt -AsSecureString
        if ($a.Length -eq 0) { if ($AllowEmpty) { return $null } ; Write-Host 'empty - again'; continue }
        if (-not $Confirm) { return $a }
        $b = Read-Host "$Prompt (again)" -AsSecureString
        if ([Net.NetworkCredential]::new('', $a).Password -ceq [Net.NetworkCredential]::new('', $b).Password) { return $a }
        Write-Host "passwords don't match - again" -ForegroundColor Yellow
    }
}

function Read-NsrootSecrets([switch]$Existing) {
    $s = @{ Existing = $Existing.IsPresent }
    if ($Existing) {
        $s.Current = Read-Secret 'current nsroot password'
        $s.New     = Read-Secret 'new nsroot password (Enter = keep the current one)' -Confirm -AllowEmpty
    } else {
        $s.Current = Read-Secret 'nsroot DEFAULT password of the image'
        $s.New     = Read-Secret 'new nsroot password' -Confirm
    }
    if ($SetRpcPassword) { $s.Rpc = Read-Secret 'RPC node password (the SAME on both HA nodes)' -Confirm }
    $s
}

function Initialize-Nsroot([string]$Ip, [hashtable]$Secrets) {
    # Fresh VPX (forced first-login change) = login with new_password; already changed (-InitNsroot) = normal login +
    # PUT systemuser (login with new_password on a non-forced account drops the connection). Then RPC node password,
    # features/modes off, save.
    $plain = { param($sec) [Net.NetworkCredential]::new('', $sec).Password }

    # NITRO can lag behind port 443 on the first boot -> retry the first contact for up to 5 min
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        try { $pin = Get-KeyPin $Ip; break }
        catch { if ((Get-Date) -gt $deadline) { throw }; Start-Sleep 15 }
    }
    Write-Host "management certificate pin (first contact): $pin" -ForegroundColor Cyan

    $s = @{ Base = "https://$Ip/nitro/v1/config"; Client = [NsVpxDeploy.Pin]::NewClient($pin, $NoProxy.IsPresent); Cookie = $null }
    try {
        $pw = $Secrets.Current
        if ($Secrets.New -and $Secrets.Existing) {
            Connect-NsNitro $s $pw
            try {
                Write-Step 'set system user nsroot (new password)' (Invoke-NsNitro -Session $s -Method PUT -Resource 'systemuser' `
                    -Body @{ systemuser = @{ username = 'nsroot'; password = (& $plain $Secrets.New) } })
            }
            finally { Disconnect-NsNitro $s }
            $pw = $Secrets.New       # the login below proves the new password
        }
        elseif ($Secrets.New) {
            while ($true) {
                try {
                    $r = Invoke-NsNitro -Session $s -Method POST -Resource 'login' -Body @{ login = @{
                        username = 'nsroot'; password = (& $plain $Secrets.Current); new_password = (& $plain $Secrets.New) } }
                }
                catch {
                    $b = $_.Exception.GetBaseException()
                    if ((Get-Date) -gt $deadline) { throw "NITRO login (password change) to https://$Ip failed (pinned $pin): $($b.GetType().Name): $($b.Message)" }
                    Write-Host "  NITRO not ready ($($b.GetType().Name): $($b.Message)) - retry in 15 s" -ForegroundColor DarkGray
                    Start-Sleep 15; continue
                }
                if ($r.ErrorCode -eq 0 -and $r.Data.sessionid) { break }
                # 5xx / "not ready" during the first minutes -> retry; wrong password etc. -> stop
                if ($r.Http -lt 500 -or (Get-Date) -gt $deadline) { throw "nsroot password change failed: $($r.ErrorCode) $($r.Message)" }
                Start-Sleep 15
            }
            $s.Cookie = "NITRO_AUTH_TOKEN=$($r.Data.sessionid)"
            Write-Host '  [OK]      nsroot password changed' -ForegroundColor Green
            Disconnect-NsNitro $s
            $pw = $Secrets.New
        }

        Write-Host "Connecting to https://$Ip as nsroot (pinned $pin)..."
        Connect-NsNitro $s $pw
        try {
            if ($Secrets.Rpc) {
                Write-Step "set ns rpcNode $Ip -secure YES" (Invoke-NsNitro -Session $s -Method PUT -Resource 'nsrpcnode' `
                    -Body @{ nsrpcnode = @{ ipaddress = $Ip; password = (& $plain $Secrets.Rpc); secure = 'YES' } })
            }
            # `disable ns feature/mode` in the first-boot userdata does not stick (14.1: CH + MBF are on again after the
            # first boot; enable lines work) -> switch them off here, after boot.
            if ($DisableFeature) {
                Write-Step "disable ns feature $($DisableFeature -join ' ')" (Invoke-NsNitro -Session $s -Method POST `
                    -Resource 'nsfeature' -Query 'action=disable' -Body @{ nsfeature = @{ feature = @($DisableFeature) } })
            }
            if ($DisableMode) {
                Write-Step "disable ns mode $($DisableMode -join ' ')" (Invoke-NsNitro -Session $s -Method POST `
                    -Resource 'nsmode' -Query 'action=disable' -Body @{ nsmode = @{ mode = @($DisableMode) } })
            }
            Write-Step 'save ns config' (Invoke-NsNitro -Session $s -Method POST -Resource 'nsconfig' -Query 'action=save' -Body @{ nsconfig = @{} })
        }
        finally { Disconnect-NsNitro $s }
    }
    finally { $s.Client.Dispose() }
    $pin
}

function Remove-UserdataIso {
    # needs the VI connection and the ds: drive; uses $VmName / $isoName of the script
    $vm = Get-VM $VmName
    $cd = Get-CDDrive -VM $vm | Where-Object IsoPath -like "*$isoName"
    if ($cd -and $vm.PowerState -eq 'PoweredOn') {
        # IDE CD drives cannot be hot-removed -> eject the ISO; the empty drive stays (harmless)
        # vSphere API directly (Set-CDDrive has no -RunAsync): reconfigure task = CD without media, not connected
        $dev = $cd.ExtensionData
        $dev.Backing = New-Object VMware.Vim.VirtualCdromRemotePassthroughBackingInfo -Property @{ DeviceName = ''; Exclusive = $false }
        $dev.Connectable.Connected = $false
        $dev.Connectable.StartConnected = $false
        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $spec.DeviceChange = @(New-Object VMware.Vim.VirtualDeviceConfigSpec -Property @{ Operation = 'edit'; Device = $dev })
        $taskRef = $vm.ExtensionData.ReconfigVM_Task($spec)
        # FreeBSD may lock the tray -> ESXi asks "override the lock?" -> answer Yes while the task waits
        $deadline = (Get-Date).AddMinutes(2)
        while (($t = Get-View $taskRef).Info.State -in 'queued', 'running') {
            Get-VMQuestion -VM $vm | ForEach-Object {
                $yes = $_.Options | Where-Object Label -match 'yes' | Select-Object -First 1
                if ($yes) { Write-Host "VM question: $($_.Text) -> $($yes.Summary)"; Set-VMQuestion $_ -Option $yes -Confirm:$false }
            }
            if ((Get-Date) -gt $deadline) { throw 'CD eject task still running after 2 min - check the VM in the ESXi host client.' }
            Start-Sleep 2
        }
        if ($t.Info.State -ne 'success') { throw "CD eject failed: $($t.Info.Error.LocalizedMessage)" }
        Write-Host 'ISO ejected (empty CD drive stays while the VM runs).' -ForegroundColor Green
    } elseif ($cd) {
        Remove-CDDrive $cd -Confirm:$false
        Write-Host 'CD drive removed.' -ForegroundColor Green
    }
    if (Test-Path "ds:\$VmName\$isoName") { Remove-Item "ds:\$VmName\$isoName"; Write-Host "$isoName deleted from the datastore." -ForegroundColor Green }
}

function Open-NsSession([string]$Ip) {
    # pinned NITRO session for the LAS modes: -NsPinnedPublicKey, else the key of the first contact (warning)
    $pin = $NsPinnedPublicKey
    if (-not $pin) {
        $pin = Get-KeyPin $Ip
        Write-Warning "management certificate of $Ip not checked - pinned on first contact: $pin (pass -NsPinnedPublicKey)."
    }
    # Password stays in memory (SecureString) for the login after -Reboot
    $s = @{ Base = "https://$Ip/nitro/v1/config"; Client = [NsVpxDeploy.Pin]::NewClient($pin, $NoProxy.IsPresent); Cookie = $null
            Password = (Read-Secret 'nsroot password') }
    Connect-NsNitro $s $s.Password
    $s
}

function Show-LasStatus([hashtable]$Session) {
    $las = @((Invoke-NsNitro -Session $Session -Method GET -Resource 'nslaslicense').Data.nslaslicense)[0]
    $lic = @((Invoke-NsNitro -Session $Session -Method GET -Resource 'nslicense').Data.nslicense)[0]
    Write-Host "LAS status: $($las.status), days to expiration: $($las.daystoexpiration)" -ForegroundColor Cyan
    Write-Host "Licensing mode: $($lic.licensingmode), model ID: $($lic.modelid)" -ForegroundColor Cyan
    $las
}

function Invoke-LasRequest {
    # = CLI 'show ns licenseactivationdata [-useHostname]': creates the request (and on the first call the VPX's
    # activation key pair) under /nsconfig/license; a second call keeps the key pair, only the request time changes.
    $s = Open-NsSession $Nsip
    try {
        $r = Invoke-NsNitro -Session $s -Method GET -Resource 'nslicenseactivationdata' -Query $(if ($UseHostname) { 'args=usehostname:true' })
        Write-Step "show ns licenseactivationdata$(if ($UseHostname) { ' -useHostname' })" $r
        $name = @($r.Data.nslicenseactivationdata)[0].filename
        if (-not $name) { throw "no file name in the NITRO answer: $($r.Data | ConvertTo-Json -Depth 5 -Compress)" }
        $f = Invoke-NsNitro -Session $s -Method GET -Resource "systemfile/$([uri]::EscapeDataString($name))" -Query 'args=filelocation:%2Fnsconfig%2Flicense'
        Write-Step "download /nsconfig/license/$name" $f
        $out = Join-Path (Resolve-Path $OutDir) $name
        [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String(@($f.Data.systemfile)[0].filecontent))
        Write-Host "saved $out ($((Get-Item $out).Length) bytes, sha256 $((Get-FileHash $out).Hash.ToLower()))" -ForegroundColor Green
        # the request is public data (no secrets): show what Citrix Cloud will see
        try {
            $j = tar -xzOf $out ns_offline_activation_request.json | ConvertFrom-Json
            Write-Host "request: hostname $($j.hostname), id $($j.lsguid), build $($j.lsbuild), last activation '$($j.renewalinput.lastactivationid)'"
        } catch { }
        Write-Host 'Next: upload it in Citrix Cloud (Licensing > NetScaler licenses > NetScaler ADC), then -LasActivate with the activation file.' -ForegroundColor Green
    }
    finally { Disconnect-NsNitro $s; $s.Client.Dispose() }
}

function Invoke-LasActivate {
    # = GUI "Upload File": add system file + apply ns laslicense -fixedBandwidth (without it: "Failed to parse")
    $file = Get-Item $ActivationFile
    $name = $file.Name
    $s = Open-NsSession $Nsip
    try {
        $body = @{ systemfile = @{ filename = $name; filelocation = '/nsconfig/license'
                                   filecontent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName)); fileencoding = 'BASE64' } }
        $r = Invoke-NsNitro -Session $s -Method POST -Resource 'systemfile' -Body $body
        if ($r.ErrorCode -ne 0 -and $r.Message -match 'exist') {
            # same name from an earlier try -> replace
            Write-Step "delete old /nsconfig/license/$name" (Invoke-NsNitro -Session $s -Method DELETE `
                -Resource "systemfile/$([uri]::EscapeDataString($name))" -Query 'args=filelocation:%2Fnsconfig%2Flicense')
            $r = Invoke-NsNitro -Session $s -Method POST -Resource 'systemfile' -Body $body
        }
        Write-Step "add system file $name -fileLocation /nsconfig/license" $r
        $a = Invoke-NsNitro -Session $s -Method POST -Resource 'nslaslicense' -Query 'action=apply' `
            -Body @{ nslaslicense = @{ filename = $name; filelocation = '/nsconfig/license'; fixedbandwidth = $true } }
        if ($a.ErrorCode -ne 0 -and $a.Message -match 'LPEID') {
            Write-Host ('The activation does not fit this VPX: it belongs to the VPX that created the request ' +
                '(other VPX, or a rebuild without the same MAC + BIOS UUID + full backup). Create a new request (-LasRequest).') -ForegroundColor Yellow
        }
        Write-Step "apply ns laslicense -fileName $name -fileLocation /nsconfig/license -fixedBandwidth" $a
        [void](Show-LasStatus $s)
        if (-not $Reboot) {
            Write-Host 'The licensing mode changes after a reboot: save ns config + reboot -warm (or run again with -Reboot).' -ForegroundColor Yellow
            return
        }
        Write-Step 'save ns config' (Invoke-NsNitro -Session $s -Method POST -Resource 'nsconfig' -Query 'action=save' -Body @{ nsconfig = @{} })
        # the VPX drops the connection while it restarts -> no answer expected
        try { [void](Invoke-NsNitro -Session $s -Method POST -Resource 'reboot' -Body @{ reboot = @{ warm = $true } }) } catch { }
        $s.Cookie = $null
        Write-Host 'warm reboot ...' -ForegroundColor Cyan

        # wait until 443 is gone and NITRO takes a login again, then show the licensing mode
        $deadline = (Get-Date).AddMinutes(2)
        while ((Test-Connection $Nsip -TcpPort 443 -Quiet) -and (Get-Date) -lt $deadline) { Start-Sleep 5 }
        $deadline = (Get-Date).AddMinutes(10)
        while ($true) {
            Start-Sleep 20
            try { Connect-NsNitro $s $s.Password; break }
            catch { if ((Get-Date) -gt $deadline) { throw "NITRO on $Nsip not back after 10 min: $($_.Exception.Message)" } }
        }
        [void](Show-LasStatus $s)
    }
    finally { Disconnect-NsNitro $s; $s.Client.Dispose() }
}

if ($InitNsroot) {
    if ($dryRun) { Write-Host "WhatIf: would log in to https://$Nsip as nsroot and change the password via NITRO." -ForegroundColor Yellow; return }
    [void](Initialize-Nsroot -Ip $Nsip -Secrets (Read-NsrootSecrets -Existing))
    return
}
if ($LasRequest) {
    if ($dryRun) { Write-Host "WhatIf: would create the LAS offline activation request on $Nsip$(if ($UseHostname) { ' (host name)' }) and download it to $OutDir." -ForegroundColor Yellow; return }
    Invoke-LasRequest
    return
}
if ($LasActivate) {
    if (-not (Test-Path $ActivationFile)) { throw "$ActivationFile not found." }
    if ($dryRun) { Write-Host "WhatIf: would upload $ActivationFile to $Nsip`:/nsconfig/license and apply it (-fixedBandwidth)$(if ($Reboot) { ', save + warm reboot' })." -ForegroundColor Yellow; return }
    Invoke-LasActivate
    return
}

if (-not $IsWindows) { throw 'Windows only: the userdata ISO is built with the Windows IMAPI2 API.' }
if (-not (Get-Module -ListAvailable VMware.VimAutomation.Core)) {
    throw 'VMware PowerCLI missing - run once: Install-Module VCF.PowerCLI -Scope CurrentUser'
}
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -ParticipateInCEIP $false -DisplayDeprecationWarnings $false -Confirm:$false | Out-Null
# PowerCLI has no key pinning -> compare the host key on a separate TLS handshake right before Connect-VIServer
if ($EsxPinnedPublicKey) {
    $esxPin = Get-KeyPin $EsxHost
    if ($esxPin -cne $EsxPinnedPublicKey) { throw "ESXi $EsxHost presents key $esxPin, expected $EsxPinnedPublicKey - stopped." }
    Write-Host "ESXi $EsxHost key matches -EsxPinnedPublicKey." -ForegroundColor DarkGray
} else {
    Write-Warning "ESXi $EsxHost certificate not checked - pass -EsxPinnedPublicKey (docs/vmware.md)."
}
$cred = Get-Credential root -Message "ESXi $EsxHost"
$null = Connect-VIServer $EsxHost -Credential $cred
$isoName = "$VmName-userdata.iso"

try {
    if ($ListOvf) {
        foreach ($d in Get-Datastore) {
            New-PSDrive -Name dsl -PSProvider VimDatastore -Root '\' -Location $d | Out-Null
            Get-ChildItem dsl:\ -Recurse -ErrorAction SilentlyContinue | Where-Object Name -match '\.ovf$' |
                ForEach-Object { '[{0}] {1}' -f $d.Name, ($_.DatastoreFullPath -replace '^\[[^\]]+\]\s*', '') }
            Remove-PSDrive dsl
        }
        return
    }

    if ($ShowIdentity) {
        # read BEFORE removing a VM whose rebuild must keep MAC / BIOS UUID (offline LAS license, DHCP, NAT)
        $vm = Get-VM $VmName
        $mac = @(Get-NetworkAdapter -VM $vm | Sort-Object Name | ForEach-Object MacAddress)
        $uuid = $vm.ExtensionData.Config.Uuid
        Write-Host "$VmName  MAC (0/1, 1/1, ...): $($mac -join ', ')"
        Write-Host "$VmName  BIOS UUID: $uuid  (.vmx: $(Format-VmxUuid $uuid))"
        Write-Host "Rebuild parameters: -NicCount $($mac.Count) -MacAddress $(($mac | ForEach-Object { "'$_'" }) -join ',') -BiosUuid '$uuid'" -ForegroundColor Green
        return
    }

    $ds = Get-Datastore $Datastore
    New-PSDrive -Name ds -PSProvider VimDatastore -Root '\' -Location $ds | Out-Null

    if ($Cleanup) {
        if ($dryRun) { Write-Host "WhatIf: would eject/remove $isoName from $VmName and delete it from $Datastore." -ForegroundColor Yellow; return }
        Remove-UserdataIso
        return
    }

    # --- checks ------------------------------------------------------------------------------------------------
    if (Get-VM $VmName -ErrorAction SilentlyContinue) { throw "VM $VmName already exists - rebuild: power off + remove the old VM first." }
    if ($MacAddress) {
        $dup = Get-VM | Get-NetworkAdapter | Where-Object MacAddress -in $MacAddress
        if ($dup) { throw "MAC $($dup[0].MacAddress) is still used by VM $($dup[0].Parent.Name) - remove that VM first." }
        Write-Host "MAC: $($MacAddress -join ', ')" -ForegroundColor Cyan
    } else { Write-Host 'MAC: generated by ESXi' -ForegroundColor DarkGray }
    if ($BiosUuid) {
        $dup = Get-VM | Where-Object { $_.ExtensionData.Config.Uuid -eq $BiosUuid }
        if ($dup) { throw "BIOS UUID $BiosUuid is still used by VM $($dup[0].Name) - remove that VM first." }
        Write-Host "BIOS UUID: $BiosUuid ($(Format-VmxUuid $BiosUuid))" -ForegroundColor Cyan
    }
    foreach ($ip in @($Nsip, $Snip) | Where-Object { $_ }) {
        if (Test-Connection $ip -Count 2 -TimeoutSeconds 1 -Quiet) { throw "$ip answers ping - address in use (old VM still running?)." }
    }
    if ($OvfPath -notmatch '^\[(?<ds>[^\]]+)\]\s*(?<p>.+\.ovf)$') { throw "-OvfPath must look like '[datastore] folder/file.ovf' (see -ListOvf)" }
    $srcDs = Get-Datastore $Matches.ds
    $srcRel = $Matches.p -replace '/', '\'
    New-PSDrive -Name src -PSProvider VimDatastore -Root '\' -Location $srcDs | Out-Null
    if (-not (Test-Path "src:\$srcRel")) { throw "$OvfPath not found (see -ListOvf)." }
    if ($ExpectBuild -and (Split-Path -Leaf $srcRel) -notmatch [regex]::Escape($ExpectBuild)) {
        Write-Warning "OVF name does not contain $ExpectBuild. HA needs the same build on both nodes."
    }

    # --- userdata (no secrets) ---------------------------------------------------------------------------------
    $cfg = @("add route 0.0.0.0 0.0.0.0 $Gateway", "set ns hostName $HostName")
    if ($Snip) { $cfg += "add ns ip $Snip $Netmask -type SNIP" }
    foreach ($d in $DnsServer) { $cfg += "add dns nameServer $d" }
    foreach ($n in $NtpServer) { $cfg += "add ntp server $n" }
    if ($NtpServer) { $cfg += 'enable ntp sync' }
    if ($ExtraConfig) {
        $extra = @(Get-Content $ExtraConfig | ForEach-Object Trim | Where-Object { $_ -and -not $_.StartsWith('#') })
        if ($extra -match 'password') { throw "$ExtraConfig contains 'password' - no secrets in the userdata ISO." }
        if ($extra -match '[<>&]') { throw "$ExtraConfig contains < > or & - not allowed inside the userdata XML." }
        $cfg += $extra
    }
    $userdata = @"
<NS-PRE-BOOT-CONFIG>
    <NS-CONFIG>
$(($cfg | ForEach-Object { "        $_" }) -join "`n")
    </NS-CONFIG>
    <NS-BOOTSTRAP>
        <SKIP-DEFAULT-BOOTSTRAP>YES</SKIP-DEFAULT-BOOTSTRAP>
        <NEW-BOOTSTRAP-SEQUENCE>YES</NEW-BOOTSTRAP-SEQUENCE>
        <MGMT-INTERFACE-CONFIG>
            <INTERFACE-NUM>eth0</INTERFACE-NUM>
            <IP>$Nsip</IP>
            <SUBNET-MASK>$Netmask</SUBNET-MASK>
        </MGMT-INTERFACE-CONFIG>
    </NS-BOOTSTRAP>
</NS-PRE-BOOT-CONFIG>
"@
    Write-Host "userdata:`n$userdata" -ForegroundColor DarkGray
    if ($dryRun) { Write-Host "WhatIf: would import $OvfPath as $VmName on $Datastore ($NumCpu vCPU, $MemoryGB GB, $NicCount NIC(s)$(if ($NicType) { " $NicType" }) on $Network$(if ($BiosUuid) { ", BIOS UUID $BiosUuid" })), attach $isoName, power on$(if (-not $SkipNsroot) { ", change the nsroot password via NITRO$(if (-not $KeepIso) { ', remove the ISO' })" })." -ForegroundColor Yellow; return }
    $secrets = if (-not $SkipNsroot) { Read-NsrootSecrets }

    $work = Join-Path ([IO.Path]::GetTempPath()) "nsvpx-$(Get-Date -f yyyyMMddHHmmss)"
    New-Item -ItemType Directory "$work\ovf", "$work\iso" | Out-Null
    try {
        # --- OVF package: .ovf + .mf + disk(s) from the same folder ---------------------------------------------
        $srcDir  = Split-Path -Parent $srcRel
        $ovfLeaf = Split-Path -Leaf $srcRel
        Copy-DatastoreItem "src:\$srcRel" "$work\ovf\"
        $refs = [xml](Get-Content -Raw "$work\ovf\$ovfLeaf")
        $files = @($refs.Envelope.References.File | ForEach-Object href) + ($ovfLeaf -replace '\.ovf$', '.mf')
        foreach ($f in $files) {
            if (Test-Path "src:\$srcDir\$f") { Write-Host "copy $f"; Copy-DatastoreItem "src:\$srcDir\$f" "$work\ovf\" }
        }
        Remove-PSDrive src

        # --- import ---------------------------------------------------------------------------------------------
        $vmhost = Get-VMHost $EsxHost -ErrorAction SilentlyContinue
        if (-not $vmhost) { $vmhost = Get-VMHost | Select-Object -First 1 }
        $vm = Import-VApp -Source "$work\ovf\$ovfLeaf" -VMHost $vmhost -Datastore $ds -Name $VmName -DiskStorageFormat Thin
        $vm = Set-VM $vm -NumCpu $NumCpu -MemoryGB $MemoryGB -Confirm:$false
        # -NicType converts the OVF's NIC(s); extra NICs get -NicType or the OVF's first NIC type
        $nics = @(Get-NetworkAdapter -VM $vm)
        if ($nics.Count -gt $NicCount) { Write-Warning "OVF brings $($nics.Count) NICs, -NicCount $NicCount - leaving them." }
        $type = if ($NicType) { $NicType } else { $nics[0].Type }
        if ($NicType) { $nics | Where-Object Type -ne $NicType | Set-NetworkAdapter -Type $NicType -Confirm:$false | Out-Null }
        for ($i = $nics.Count; $i -lt $NicCount; $i++) {
            New-NetworkAdapter -VM $vm -NetworkName $Network -Type $type -StartConnected -Confirm:$false | Out-Null
        }
        Write-Host "NICs: $NicCount x $type" -ForegroundColor DarkGray
        if ($MacAddress) { $vm = Set-VmStaticMac -Vm $vm -Mac $MacAddress -WorkDir $work }
        if ($BiosUuid) { $vm = Set-VmBiosUuid -Vm $vm -Uuid $BiosUuid }
        Get-NetworkAdapter -VM $vm | Set-NetworkAdapter -NetworkName $Network -StartConnected:$true -Confirm:$false | Out-Null

        # --- userdata ISO -> datastore -> CD drive ---------------------------------------------------------------
        Set-Content -Path "$work\iso\userdata" -Value $userdata -NoNewline -Encoding ascii
        New-UserdataIso -Dir "$work\iso" -Out "$work\$isoName"
        Copy-DatastoreItem "$work\$isoName" "ds:\$VmName\"
        New-CDDrive -VM $vm -IsoPath "[$Datastore] $VmName/$isoName" -StartConnected | Out-Null

        Start-VM $vm | Out-Null
        $mac = @(Get-NetworkAdapter -VM $vm | Sort-Object Name | ForEach-Object MacAddress)
        if ($MacAddress -and (Compare-Object $mac $MacAddress -SyncWindow 0)) { Write-Warning "VM runs with MAC $($mac -join ', '), expected $($MacAddress -join ', ')." }
        Write-Host "$VmName powered on (MAC $($mac -join ', ')). Waiting for $Nsip`:443 (first boot takes a few minutes) ..." -ForegroundColor Cyan
        $cleanupCmd = "& '$PSCommandPath' -EsxHost $EsxHost$(if ($EsxPinnedPublicKey) { " -EsxPinnedPublicKey '$EsxPinnedPublicKey'" }) -VmName $VmName -Datastore $Datastore -Cleanup"
        try {
            $deadline = (Get-Date).AddMinutes(15)
            while (-not (Test-Connection $Nsip -TcpPort 443 -Quiet)) {
                if ((Get-Date) -gt $deadline) { throw "$Nsip`:443 not reachable after 15 min - check the VM console in the ESXi host client." }
                Start-Sleep 15
            }
            if ($secrets) {
                Write-Host "$Nsip`:443 is up. nsroot password via NITRO ..." -ForegroundColor Cyan
                $pin = Initialize-Nsroot -Ip $Nsip -Secrets $secrets
            }
        }
        catch {
            # first boot not confirmed -> keep the userdata ISO for diagnosis
            Write-Host "Userdata ISO kept for diagnosis. Remove it later with:`n  $cleanupCmd" -ForegroundColor Yellow
            throw
        }
        if (-not $secrets) {
            # -SkipNsroot: the first boot is not confirmed by a login -> keep the ISO
            Write-Host "$Nsip`:443 is up. Change the nsroot password (first login or -InitNsroot), then:`n  $cleanupCmd" -ForegroundColor Green
            return
        }
        # the NITRO login proved the first boot applied the userdata -> the ISO has done its job
        if ($KeepIso) {
            Write-Host "Userdata ISO kept (-KeepIso). Remove it later with:`n  $cleanupCmd" -ForegroundColor Yellow
        } else {
            try   { Remove-UserdataIso }
            catch { Write-Warning "VPX is ready, but the userdata ISO was not removed: $($_.Exception.Message)`n  Retry with: $cleanupCmd" }
        }
        Write-Host "Done. Management key pin for the next NITRO tools: $pin" -ForegroundColor Green
    }
    finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}
finally {
    Get-PSDrive ds, src -ErrorAction SilentlyContinue | Remove-PSDrive
    Disconnect-VIServer $EsxHost -Confirm:$false
}
