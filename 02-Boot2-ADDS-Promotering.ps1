#Requires -RunAsAdministrator
<#
    02-Boot2-ADDS-Promotering.ps1
    -------------------------------------------------------------
    Kjøres etter restart fra boot 1 (navn og statisk IP er satt).

    Gjør:
      - Installerer AD DS + DNS-rollene
      - Promoterer serveren til domenekontroller i en ny skog

    Install-ADDSForest restarter serveren AUTOMATISK når promoteringen
    er ferdig - du trenger ikke restarte manuelt etter dette skriptet.

    NESTE STEG (etter automatisk restart):
    03-Boot3-DHCP-AD-Deling-Skriver-GPO-Backup.ps1
    -------------------------------------------------------------
#>

$DomeneNavn  = "ad.vardeholm.no"
$NetBIOS     = "VARDEHOLM"
$DSRMPassord = Read-Host "Oppgi DSRM-passord" -AsSecureString

try {
    if (-not (Get-WindowsFeature AD-Domain-Services).Installed) {
        Install-WindowsFeature -Name AD-Domain-Services, DNS `
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
    Write-Error "Feil ved ADDS-promotering (boot 2): $_"
}
