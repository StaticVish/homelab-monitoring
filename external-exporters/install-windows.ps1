# Windows 11 / Windows Server automated installer for windows_exporter
# Run in an elevated PowerShell session (Run as Administrator)

[CmdletBinding()]
param (
    [string]$Version = "0.28.2",
    [int]$ListenPort = 9182,
    [string]$Collectors = "cpu,cs,logical_disk,net,os,service,system,tcp"
)

# 1. Require Administrative Privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be executed as Administrator. Please open PowerShell as Administrator and retry."
    exit 1
}

Write-Host "==> Installing Prometheus windows_exporter v$Version on Windows..." -ForegroundColor Cyan

# 2. Determine Architecture
$arch = "amd64"
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    $arch = "arm64"
}

$msiName = "windows_exporter-$Version-$arch.msi"
$downloadUrl = "https://github.com/prometheus-community/windows_exporter/releases/download/v$Version/$msiName"
$tempMsi = Join-Path $env:TEMP $msiName

# 3. Download the MSI Installer
Write-Host "==> Downloading $downloadUrl to $tempMsi..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $downloadUrl -OutFile $tempMsi -UseBasicParsing

# 4. Install the MSI silently with chosen collectors and port
Write-Host "==> Installing windows_exporter as a Windows Service..." -ForegroundColor Cyan
$installArgs = @(
    "/i",
    "`"$tempMsi`"",
    "LISTEN_PORT=$ListenPort",
    "ENABLED_COLLECTORS=$Collectors",
    "/qn",
    "/norestart"
)

$process = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru
if ($process.ExitCode -ne 0) {
    Write-Error "MSI installation failed with exit code $($process.ExitCode)"
    exit $process.ExitCode
}

# 5. Configure Windows Firewall for Tailscale subnet
Write-Host "==> Configuring Windows Defender Firewall rule for Tailscale (port $ListenPort)..." -ForegroundColor Cyan
$ruleName = "Prometheus-windows_exporter-Tailscale"
Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

# Tailscale CGNAT subnet is 100.64.0.0/10
New-NetFirewallRule `
    -DisplayName $ruleName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort $ListenPort `
    -RemoteAddress "100.64.0.0/10" `
    -Description "Allow Prometheus scraping from Tailscale network" | Out-Null

# 6. Verify Service Status
Start-Sleep -Seconds 2
$svc = Get-Service -Name "windows_exporter" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "==> [SUCCESS] windows_exporter is running on port $ListenPort!" -ForegroundColor Green
    Write-Host "    Metrics endpoint: http://localhost:$ListenPort/metrics" -ForegroundColor Green
} else {
    Write-Warning "windows_exporter service is installed but not reported as Running. Current status: $($svc.Status)"
    Start-Service -Name "windows_exporter"
}

# Clean up installer file
Remove-Item -Path $tempMsi -Force -ErrorAction SilentlyContinue
