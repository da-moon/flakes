# 01-install-tailscale-windows.ps1
$ErrorActionPreference = 'Stop'

function Assert-Admin {
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in an elevated PowerShell session."
  }
}

Assert-Admin

# Detect CPU arch. Tailscale's Windows MSI docs say ARM64 should use x86 MSI.
$procArch = $env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()
switch ($procArch) {
  'ARM64' { $msiArch = 'x86' }
  'AMD64' { $msiArch = 'amd64' }
  'X86'   { $msiArch = 'x86' }
  default { throw "Unsupported PROCESSOR_ARCHITECTURE: $procArch" }
}

$index = Invoke-WebRequest -UseBasicParsing 'https://pkgs.tailscale.com/stable/'
$regex = "tailscale-setup-[0-9.]+-$msiArch\.msi"
$match = [regex]::Match($index.Content, $regex)

if (-not $match.Success) {
  throw "Could not locate a stable Tailscale MSI for architecture $msiArch."
}

$msiName = $match.Value
$msiUrl  = "https://pkgs.tailscale.com/stable/$msiName"

$tempDir = Join-Path $env:TEMP 'tailscale-install'
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$msiPath = Join-Path $tempDir $msiName
$logPath = Join-Path $tempDir 'tailscale-msi.log'

Invoke-WebRequest -UseBasicParsing $msiUrl -OutFile $msiPath

$msiArgs = @(
  '/i', "`"$msiPath`"",
  '/qn',
  '/L*v', "`"$logPath`"",
  'TS_UNATTENDEDMODE="always"',
  'TS_ALLOWINCOMINGCONNECTIONS="always"',
  'TS_INSTALLUPDATES="always"'
)

$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
  throw "msiexec failed with exit code $($proc.ExitCode). See $logPath"
}

Write-Host ''
Write-Host 'Tailscale installed.'
Write-Host 'Next: sign in on the Windows host from the Tailscale tray icon.'
Write-Host 'Then verify with:'
Write-Host '  "$env:ProgramFiles\Tailscale\tailscale.exe" status'