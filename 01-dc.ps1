# 01-Grunnoppsett.ps1 - Grunnkonfig av server: navn og statisk IP
# Variabler (endres per server)
$NyttNavn   = "dc01"
$IPAdresse  = "10.0.0.2"
$Prefiks    = 24
$Gateway    = "10.0.0.1"
$DNS        = "127.0.0.1"          # DC peker på seg selv etter DNS-installasjon
$IfAlias    = "Ethernet"

try {
    # Sett statisk IP hvis den ikke allerede er satt (idempotent)
    if (-not (Get-NetIPAddress -IPAddress $IPAdresse -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceAlias $IfAlias -IPAddress $IPAdresse `
            -PrefixLength $Prefiks -DefaultGateway $Gateway -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceAlias $IfAlias -ServerAddresses $DNS
        Write-Host "Statisk IP satt: $IPAdresse"
    } else {
        Write-Host "IP allerede satt - hopper over."
    }

    # Endre datamaskinnavn hvis nødvendig
    if ($env:COMPUTERNAME -ne $NyttNavn) {
        Rename-Computer -NewName $NyttNavn -Force
        Write-Host "Navn endret til $NyttNavn. Omstart kreves."
    }
} catch {
    Write-Error "Feil i grunnoppsett: $_"
}
