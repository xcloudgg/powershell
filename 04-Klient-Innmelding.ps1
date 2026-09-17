04-Klient-Innmelding.ps1
#Requires -RunAsAdministrator
<#
    04-Klient-Innmelding.ps1
    -------------------------------------------------------------
    Kjøres på KLIENT-PC-en (ikke på dc01), etter at dc01 er ferdig
    satt opp (boot 1-3). Dette er ikke en del av serverens boot-
    rekkefølge, men tas med her siden den hører til samme oppsett.
 
    DNS må peke på DC-en for at innmelding og GPO skal virke, derfor
    settes DNS eksplisitt til dc01 sin IP (10.0.0.10) før innmelding.
    -------------------------------------------------------------
#>
 
$Domene = "eikerikt.com"
$OU     = "OU=Kontor,OU=Datamaskiner,OU=eiker,DC=no"
$DcIP   = "10.0.0.10"
 
try {
    Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses $DcIP
 
    Add-Computer -DomainName $Domene -OUPath $OU `
        -Credential (Get-Credential) -Restart -ErrorAction Stop
} catch {
    Write-Error "Feil ved domeneinnmelding: $_"
}
 
