<#
.SYNOPSIS
    Installs OpenSSH Server on Windows and enables password authentication.

.DESCRIPTION
    - Installs the OpenSSH Server Windows capability (if not already present)
    - Starts the sshd service and sets it to start automatically on boot
    - Opens the Windows Firewall for inbound TCP port 22
    - Edits sshd_config to explicitly enable PasswordAuthentication
    - Restarts sshd so the new config takes effect

.NOTES
    Must be run as Administrator (in an elevated PowerShell window).
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

Write-Host "=== SSH Server Setup ===" -ForegroundColor Cyan

# 1. Install the OpenSSH Server capability
$sshServerFeature = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'

if ($sshServerFeature.State -ne 'Installed') {
    Write-Host "[1/5] Installing OpenSSH Server..." -ForegroundColor Yellow
    Add-WindowsCapability -Online -Name $sshServerFeature.Name | Out-Null
} else {
    Write-Host "[1/5] OpenSSH Server is already installed." -ForegroundColor Green
}

# 2. Start the sshd service and set it to start automatically
Write-Host "[2/5] Starting sshd service and setting it to Automatic..." -ForegroundColor Yellow
Start-Service sshd
Set-Service -Name sshd -StartupType 'Automatic'

# 3. Ensure the firewall rule for SSH (port 22) exists
Write-Host "[3/5] Checking firewall rule for port 22..." -ForegroundColor Yellow
$fwRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue

if (-not $fwRule) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
        -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort 22 | Out-Null
    Write-Host "     Firewall rule created." -ForegroundColor Green
} else {
    Write-Host "     Firewall rule already exists." -ForegroundColor Green
}

# 4. Enable password authentication in sshd_config
Write-Host "[4/5] Configuring sshd_config for password authentication..." -ForegroundColor Yellow
$sshdConfigPath = "$env:ProgramData\ssh\sshd_config"

if (-not (Test-Path $sshdConfigPath)) {
    throw "sshd_config not found at $sshdConfigPath. Is OpenSSH Server installed correctly?"
}

$config = Get-Content $sshdConfigPath

# Set (or add) PasswordAuthentication yes
if ($config -match '^\s*#?\s*PasswordAuthentication\b') {
    $config = $config -replace '^\s*#?\s*PasswordAuthentication\b.*', 'PasswordAuthentication yes'
} else {
    $config += 'PasswordAuthentication yes'
}

# Make sure PermitEmptyPasswords stays disabled (safe default)
if ($config -match '^\s*#?\s*PermitEmptyPasswords\b') {
    $config = $config -replace '^\s*#?\s*PermitEmptyPasswords\b.*', 'PermitEmptyPasswords no'
} else {
    $config += 'PermitEmptyPasswords no'
}

Set-Content -Path $sshdConfigPath -Value $config -Encoding UTF8
Write-Host "     sshd_config updated." -ForegroundColor Green

# 5. Restart sshd so the config change takes effect
Write-Host "[5/5] Restarting sshd service..." -ForegroundColor Yellow
Restart-Service sshd

Write-Host "`n=== Done ===" -ForegroundColor Cyan
Write-Host "SSH server is installed, running, and set to start automatically."
Write-Host "Password authentication is enabled."
Write-Host "Firewall is open on TCP port 22."
Write-Host "`nTest from another machine with:"
Write-Host "  ssh <username>@<this-machine-ip-or-hostname>" -ForegroundColor White
