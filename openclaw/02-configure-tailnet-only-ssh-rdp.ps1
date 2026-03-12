# 02-configure-tailnet-only-ssh-rdp.ps1
$ErrorActionPreference = 'Stop'

# ----- EDIT THESE -----
# Use the Windows account that already owns your WSL distro / OpenClaw environment.
$TargetWindowsUser = 'YOUR_WINDOWS_USERNAME'

# Set $true if that Windows account is an administrator.
$TargetUserIsAdministrator = $true

# Paste the Tailscale IPv4 addresses of the client devices you trust.
$TrustedTailnetIPs = @(
  '100.111.112.113',
  '100.121.122.123'
)

# Paste one or more SSH public keys that are allowed to log in.
$AuthorizedPublicKeys = @(
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... your-main-laptop',
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... your-backup-device'
)

# Set to $false if your Windows account naming is unusual and the AllowUsers line causes trouble.
$UseAllowUsers = $true

# Set to $true if you also want sshd to bind only to the current Tailscale IP.
# If the device ever gets a different Tailscale IP, rerun the script.
$BindSshToTailscaleIP = $false

# Makes SSH land in PowerShell instead of cmd.exe.
$SetPowerShellAsDefaultSshShell = $true
# ----------------------

function Assert-Admin {
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this in an elevated PowerShell session."
  }
}

Assert-Admin

# Find active Tailscale adapter + IP
$TsAdapter = Get-NetAdapter | Where-Object {
  $_.Status -eq 'Up' -and ($_.Name -match 'Tailscale' -or $_.InterfaceDescription -match 'Tailscale')
} | Select-Object -First 1

if (-not $TsAdapter) {
  throw "No active Tailscale adapter found. Install/sign in to Tailscale on Windows first."
}

$TsIf = $TsAdapter.Name
$TsIp = Get-NetIPAddress -InterfaceAlias $TsIf -AddressFamily IPv4 |
  Select-Object -First 1 -ExpandProperty IPAddress

if (-not $TsIp) {
  throw "No Tailscale IPv4 found on interface '$TsIf'."
}

Write-Host "Using Tailscale interface: $TsIf"
Write-Host "Using Tailscale IP:        $TsIp"

# Install / start OpenSSH Server
$sshdCap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($sshdCap.State -ne 'Installed') {
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
}

Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

if ($SetPowerShellAsDefaultSshShell) {
  New-ItemProperty `
    -Path 'HKLM:\SOFTWARE\OpenSSH' `
    -Name 'DefaultShell' `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    -PropertyType String `
    -Force | Out-Null
}

# Install authorized_keys
if ($TargetUserIsAdministrator) {
  $KeyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
  New-Item -ItemType Directory -Path (Split-Path $KeyFile) -Force | Out-Null
  ($AuthorizedPublicKeys -join "`r`n") | Set-Content -Path $KeyFile -Encoding ascii
  icacls.exe $KeyFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
} else {
  $SshDir  = Join-Path "C:\Users\$TargetWindowsUser" '.ssh'
  $KeyFile = Join-Path $SshDir 'authorized_keys'
  New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
  ($AuthorizedPublicKeys -join "`r`n") | Set-Content -Path $KeyFile -Encoding ascii
  icacls.exe $SshDir  /inheritance:r /grant:r "$TargetWindowsUser:(OI)(CI)F" /grant:r "Administrators:(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F" | Out-Null
  icacls.exe $KeyFile /inheritance:r /grant:r "$TargetWindowsUser:F"        /grant:r "Administrators:F"        /grant:r "SYSTEM:F"        | Out-Null
}

# Add / replace a managed hardening block in sshd_config
$ConfigPath = Join-Path $env:ProgramData 'ssh\sshd_config'
if (-not (Test-Path $ConfigPath)) {
  New-Item -ItemType File -Path $ConfigPath -Force | Out-Null
}

$BackupPath = "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $ConfigPath $BackupPath -Force

$ConfigRaw = Get-Content -Raw $ConfigPath
$ConfigRaw = [regex]::Replace($ConfigRaw, '(?ms)# BEGIN TAILNET HARDENING.*?# END TAILNET HARDENING\s*', '')

$AllowUsersLine = ''
if ($UseAllowUsers) {
  $AllowUsersEntries = $TrustedTailnetIPs | ForEach-Object { "$($TargetWindowsUser.ToLowerInvariant())@$_" }
  $AllowUsersLine = 'AllowUsers ' + ($AllowUsersEntries -join ' ')
}

$ListenAddressLine = if ($BindSshToTailscaleIP) { "ListenAddress $TsIp" } else { '' }
$DenyAdminSshLine  = if (-not $TargetUserIsAdministrator) { 'DenyGroups administrators' } else { '' }

$ManagedBlock = @"
# BEGIN TAILNET HARDENING
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
GSSAPIAuthentication no
$ListenAddressLine
$AllowUsersLine
$DenyAdminSshLine
AllowTcpForwarding no
GatewayPorts no
MaxAuthTries 3
MaxSessions 1
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
# END TAILNET HARDENING
"@

$NewConfig = ($ConfigRaw.TrimEnd() + "`r`n`r`n" + $ManagedBlock + "`r`n")
Set-Content -Path $ConfigPath -Value $NewConfig -Encoding ascii

$SshdExe = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
& $SshdExe -t
if ($LASTEXITCODE -ne 0) {
  Copy-Item $BackupPath $ConfigPath -Force
  throw "sshd_config validation failed. Original config restored from $BackupPath"
}

Restart-Service sshd

# Replace broad SSH firewall rule with a Tailscale-only rule
Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'SSH over Tailscale only' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

New-NetFirewallRule `
  -DisplayName 'SSH over Tailscale only' `
  -Direction Inbound `
  -Action Allow `
  -Profile Any `
  -Protocol TCP `
  -LocalPort 22 `
  -InterfaceAlias $TsIf `
  -LocalAddress $TsIp `
  -RemoteAddress $TrustedTailnetIPs | Out-Null

# Enable RDP
Set-ItemProperty `
  -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
  -Name 'fDenyTSConnections' `
  -Value 0

# Require NLA
$Rdp = Get-CimInstance `
  -Namespace 'root/CIMV2/TerminalServices' `
  -ClassName 'Win32_TSGeneralSetting' `
  -Filter "TerminalName='RDP-tcp'"

Invoke-CimMethod `
  -InputObject $Rdp `
  -MethodName 'SetUserAuthenticationRequired' `
  -Arguments @{ UserAuthenticationRequired = 1 } | Out-Null

# Only needed for non-admin accounts
if (-not $TargetUserIsAdministrator) {
  try {
    Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $TargetWindowsUser -ErrorAction Stop
  } catch {
    if ($_.Exception.Message -notmatch 'already a member') { throw }
  }
}

# Replace broad RDP firewall rules with Tailscale-only rules
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
Get-NetFirewallRule -DisplayName 'RDP over Tailscale only (TCP)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName 'RDP over Tailscale only (UDP)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

New-NetFirewallRule `
  -DisplayName 'RDP over Tailscale only (TCP)' `
  -Direction Inbound `
  -Action Allow `
  -Profile Any `
  -Protocol TCP `
  -LocalPort 3389 `
  -InterfaceAlias $TsIf `
  -LocalAddress $TsIp `
  -RemoteAddress $TrustedTailnetIPs | Out-Null

New-NetFirewallRule `
  -DisplayName 'RDP over Tailscale only (UDP)' `
  -Direction Inbound `
  -Action Allow `
  -Profile Any `
  -Protocol UDP `
  -LocalPort 3389 `
  -InterfaceAlias $TsIf `
  -LocalAddress $TsIp `
  -RemoteAddress $TrustedTailnetIPs | Out-Null

Write-Host ''
Write-Host 'Done.'
Write-Host "Tailscale interface : $TsIf"
Write-Host "Tailscale IP        : $TsIp"
Write-Host "SSH user            : $TargetWindowsUser"
Write-Host ''
Write-Host 'Test SSH:'
Write-Host "  ssh $TargetWindowsUser@$TsIp"
Write-Host ''
Write-Host 'Test RDP from Windows:'
Write-Host "  mstsc /v:$TsIp"