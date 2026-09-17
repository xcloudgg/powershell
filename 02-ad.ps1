# 02-ADDS.ps1 - Installer AD DS + DNS og promoter til domenekontroller (ny skog)
$DomeneNavn  = "eikerikt.com"
$NetBIOS     = "EIKT"
$DSRMPassord = Read-Host "Hokksund" -AsSecureString

try {
    if (-not (Get-WindowsFeature AD-Domain-Services).Installed) {
        Install-WindowsFeature -Name AD-Domain-Services,DNS `
            -IncludeManagementTools -ErrorAction Stop
    }
    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName $DomeneNavn `
        -DomainNetbiosName $NetBIOS `
        -InstallDns `
        -SafeModeAdministratorPassword $DSRMPassord `
        -ForestMode "WinThreshold" `
        -DomainMode "WinThreshold" `
        -Force
    # Serveren restarter automatisk etter vellykket promotering.
} catch {
    Write-Error "Feil ved ADDS-promotering: $_"
}
