#Requires -RunAsAdministrator
<#
    01-Boot1-Nettverk-Navn.ps1
    -------------------------------------------------------------
    Kjøres ved FØRSTE oppstart av en fersk Windows Server-installasjon,
    før serveren er noe som helst (verken DC, DHCP eller filserver).

    Gjør:
      - Setter statisk IP-adresse
      - Endrer datamaskinnavn til dc01

    Navneendring krever restart for å tre fullt i kraft, så skriptet
    restarter automatisk til slutt dersom navnet ble endret.

    NESTE STEG (etter restart): 02-Boot2-ADDS-Promotering.ps1
    -------------------------------------------------------------
#>

$NyttNavn   = "dc01"
$IPAdresse  = "10.0.0.10"
$Prefiks    = 24
$Gateway    = "10.0.0.1"
$DNS        = "127.0.0.1"          # DC peker på seg selv etter DNS-installasjon i boot 2
$IfAlias    = "Ethernet"           # Bytt til riktig adapternavn hvis nødvendig (se Get-NetAdapter)

$restartKreves = $false

try {
    # Statisk IP (idempotent)
    if (-not (Get-NetIPAddress -IPAddress $IPAdresse -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceAlias $IfAlias -IPAddress $IPAdresse `
            -PrefixLength $Prefiks -DefaultGateway $Gateway -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceAlias $IfAlias -ServerAddresses $DNS
        Write-Host "Statisk IP satt: $IPAdresse"
    } else {
        Write-Host "IP allerede satt - hopper over."
    }

    # Datamaskinnavn (idempotent)
    if ($env:COMPUTERNAME -ne $NyttNavn) {
        Rename-Computer -NewName $NyttNavn -Force -ErrorAction Stop
        Write-Host "Navn endret til $NyttNavn. Restart kreves før neste skript."
        $restartKreves = $true
    } else {
        Write-Host "Navn er allerede $NyttNavn - hopper over."
    }
} catch {
    Write-Error "Feil i grunnoppsett (boot 1): $_"
    return
}

if ($restartKreves) {
    Write-Host "Restarter om 10 sekunder for at navneendringen skal tre i kraft ..."
    Start-Sleep -Seconds 10
    Restart-Computer -Force
} else {
    Write-Host "Boot 1 ferdig - ingen restart nødvendig. Klar for 02-Boot2-ADDS-Promotering.ps1."
}
