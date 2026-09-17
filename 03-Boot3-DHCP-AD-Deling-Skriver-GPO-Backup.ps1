#Requires -RunAsAdministrator
<#
    03-Boot3-DHCP-AD-Deling-Skriver-GPO-Backup.ps1
    -------------------------------------------------------------
    Kjøres etter den automatiske restarten fra boot 2 (serveren er nå
    domenekontroller for ad.vardeholm.no).

    Ingen av stegene under krever restart, så alt kan kjøres i samme
    økt:
      1. DHCP (rolle, autorisering, scopes)
      2. OU-struktur og AGDLP-grupper
      3. Brukere fra CSV
      4. Fildeling (SMB + NTFS)
      5. Print-server, driver, skriver
      6. GPO som låser lager-PC-ene
      7. Windows Server Backup + AD Recycle Bin

    Forutsetter at brukere.csv ligger i samme mappe som dette skriptet.
    -------------------------------------------------------------
#>

Import-Module ActiveDirectory
Import-Module GroupPolicy

#region 1) DHCP
$ServerIP   = "10.0.0.10"
$ServerFQDN = "dc01.ad.eikerikt.com"

try {
    if (-not (Get-WindowsFeature DHCP).Installed) {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop
    }
    if (-not (Get-DhcpServerInDC | Where-Object { $_.IPAddress -eq $ServerIP })) {
        Add-DhcpServerInDC -DnsName $ServerFQDN -IPAddress $ServerIP
    }

    # Scope for ansatte (VLAN 20)
    if (-not (Get-DhcpServerv4Scope -ScopeId 10.0.10.0 -ErrorAction SilentlyContinue)) {
        Add-DhcpServerv4Scope -Name "Ansatte" -StartRange 10.0.10.50 `
            -EndRange 10.0.10.250 -SubnetMask 255.255.255.0 -State Active
        Set-DhcpServerv4OptionValue -ScopeId 10.0.10.0 -Router 10.10.20.1 `
            -DnsServer $ServerIP -DnsDomain "ad.eikerikt.com"
    }
    # Scope for lager (VLAN 30)
    if (-not (Get-DhcpServerv4Scope -ScopeId 10.10.30.0 -ErrorAction SilentlyContinue)) {
        Add-DhcpServerv4Scope -Name "Lager" -StartRange 10.10.30.50 `
            -EndRange 10.10.30.250 -SubnetMask 255.255.255.0 -State Active
        Set-DhcpServerv4OptionValue -ScopeId 10.10.30.0 -Router 10.10.30.1 `
            -DnsServer $ServerIP -DnsDomain "ad.vardeholm.no"
    }
} catch {
    Write-Error "Feil i DHCP-konfig: $_"
}
#endregion

#region 2) OU-struktur og AGDLP-grupper
$Base       = "DC=ad,DC=vardeholm,DC=no"
$Avdelinger = "Okonomi", "Salg", "Lager", "Ledelse"

try {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Vardeholm'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name "Vardeholm" -Path $Base -ProtectedFromAccidentalDeletion $true
    }
    $VPath = "OU=Vardeholm,$Base"

    foreach ($sub in "Brukere", "Datamaskiner", "Grupper") {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$sub'" -SearchBase $VPath -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $sub -Path $VPath -ProtectedFromAccidentalDeletion $true
        }
    }

    foreach ($a in $Avdelinger) {
        $p = "OU=Brukere,$VPath"
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$a'" -SearchBase $p -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $a -Path $p -ProtectedFromAccidentalDeletion $true
        }
    }

    $dp = "OU=Datamaskiner,$VPath"
    foreach ($d in "Kontor", "LagerPCer") {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$d'" -SearchBase $dp -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $d -Path $dp -ProtectedFromAccidentalDeletion $true
        }
    }

    $gp = "OU=Grupper,$VPath"
    foreach ($a in ($Avdelinger + "Felles")) {
        $grupper = @{ "GG_$a" = "Global"; "DL_${a}_RW" = "DomainLocal"; "DL_${a}_R" = "DomainLocal" }
        foreach ($g in $grupper.Keys) {
            if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
                New-ADGroup -Name $g -GroupScope $grupper[$g] -GroupCategory Security -Path $gp
            }
        }
    }
} catch {
    Write-Error "Feil i OU/gruppe-oppsett: $_"
}
#endregion

#region 3) Brukere fra CSV
$BaseBrukere = "OU=Brukere,OU=Vardeholm,DC=ad,DC=vardeholm,DC=no"
$UPNSuffiks  = "vardeholm.no"                          # matcher M365 / Entra
$StartPw     = ConvertTo-SecureString "Start!2026Vard" -AsPlainText -Force
$CsvSti      = Join-Path $PSScriptRoot "brukere.csv"

try {
    $brukere = Import-Csv -Path $CsvSti -Encoding UTF8
    foreach ($b in $brukere) {
        $sam = $b.Brukernavn
        if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
            Write-Host "Bruker finnes allerede: $sam - hopper over."
            continue
        }
        $ouPath = "OU=$($b.Avdeling),$BaseBrukere"
        New-ADUser `
            -Name "$($b.Fornavn) $($b.Etternavn)" `
            -GivenName $b.Fornavn -Surname $b.Etternavn `
            -SamAccountName $sam `
            -UserPrincipalName "$sam@$UPNSuffiks" `
            -Path $ouPath `
            -AccountPassword $StartPw `
            -ChangePasswordAtLogon $true `
            -Enabled $true
        Add-ADGroupMember -Identity "GG_$($b.Avdeling)" -Members $sam
        Write-Host "Opprettet: $sam i $($b.Avdeling)"
    }
} catch {
    Write-Error "Feil ved brukeropprettelse: $_"
}
#endregion

#region 4) Fildeling (SMB + NTFS)
$Rot = "D:\Deling"
$Avd = "Okonomi", "Salg", "Lager", "Ledelse", "Felles"

try {
    foreach ($a in $Avd) {
        $sti = Join-Path $Rot $a
        if (-not (Test-Path $sti)) { New-Item -Path $sti -ItemType Directory | Out-Null }

        # SMB-share (idempotent). Faktisk tilgang styres av NTFS.
        if (-not (Get-SmbShare -Name $a -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name $a -Path $sti `
                -FullAccess "VARDEHOLM\Domain Admins" `
                -ChangeAccess "Authenticated Users"
        }

        # NTFS: deaktiver arv, sett rettighet via DL-gruppe
        $acl = Get-Acl $sti
        $acl.SetAccessRuleProtection($true, $false)
        $rwRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "VARDEHOLM\DL_${a}_RW", "Modify",
            "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($rwRule)
        $sysRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "SYSTEM", "FullControl",
            "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($sysRule)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "VARDEHOLM\Domain Admins", "FullControl",
            "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($adminRule)
        Set-Acl -Path $sti -AclObject $acl
    }

    # Ledelse: lesetilgang til de tre avdelingsmappene
    foreach ($a in "Okonomi", "Salg", "Lager") {
        $sti = Join-Path $Rot $a
        $acl = Get-Acl $sti
        $rRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "VARDEHOLM\DL_Ledelse_R", "ReadAndExecute",
            "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($rRule)
        Set-Acl -Path $sti -AclObject $acl
    }
} catch {
    Write-Error "Feil i fildeling: $_"
}
#endregion

#region 5) Print-server, driver, skriver
try {
    if (-not (Get-WindowsFeature Print-Server).Installed) {
        Install-WindowsFeature -Name Print-Server -IncludeManagementTools -ErrorAction Stop
    }

    # Driveren må være tilgjengelig i driverstore på serveren
    if (-not (Get-PrinterDriver -Name "HP Universal Printing PCL 6" -ErrorAction SilentlyContinue)) {
        Add-PrinterDriver -Name "HP Universal Printing PCL 6"
    }

    # Eksempel: skriver for Salg (VLAN 40)
    if (-not (Get-PrinterPort -Name "IP_10.10.40.21" -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name "IP_10.10.40.21" -PrinterHostAddress "10.10.40.21"
    }
    if (-not (Get-Printer -Name "Salg-HP" -ErrorAction SilentlyContinue)) {
        Add-Printer -Name "Salg-HP" -DriverName "HP Universal Printing PCL 6" `
            -PortName "IP_10.10.40.21" -Shared -ShareName "Salg-HP"
    }
} catch {
    Write-Error "Feil ved skriveroppsett: $_"
}
#endregion

#region 6) GPO - lås lager-PC-ene
$GpoNavn = "Lager-PC Laasing"
$OUsti   = "OU=LagerPCer,OU=Datamaskiner,OU=Vardeholm,DC=ad,DC=vardeholm,DC=no"

try {
    if (-not (Get-GPO -Name $GpoNavn -ErrorAction SilentlyContinue)) {
        New-GPO -Name $GpoNavn | Out-Null
    }

    # Skjul Kontrollpanel og Innstillinger (bruker)
    Set-GPRegistryValue -Name $GpoNavn `
        -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
        -ValueName "NoControlPanel" -Type DWord -Value 1

    # Blokker Windows Installer (hindrer .msi-installasjon) - maskin
    Set-GPRegistryValue -Name $GpoNavn `
        -Key "HKLM\Software\Policies\Microsoft\Windows\Installer" `
        -ValueName "DisableMSI" -Type DWord -Value 1

    # Deaktiver regedit og cmd (bruker)
    Set-GPRegistryValue -Name $GpoNavn `
        -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
        -ValueName "DisableRegistryTools" -Type DWord -Value 1
    Set-GPRegistryValue -Name $GpoNavn `
        -Key "HKCU\Software\Policies\Microsoft\Windows\System" `
        -ValueName "DisableCMD" -Type DWord -Value 1

    # Loopback processing i Replace-modus (maskin) - gjelder uansett bruker
    Set-GPRegistryValue -Name $GpoNavn `
        -Key "HKLM\Software\Policies\Microsoft\Windows\System" `
        -ValueName "UserPolicyMode" -Type DWord -Value 1

    # Lenk GPO til OU (idempotent)
    $lenker = (Get-GPInheritance -Target $OUsti).GpoLinks.DisplayName
    if ($lenker -notcontains $GpoNavn) {
        New-GPLink -Name $GpoNavn -Target $OUsti -LinkEnabled Yes
    }
} catch {
    Write-Error "Feil i GPO-oppsett: $_"
}
#endregion

#region 7) Backup + AD Recycle Bin
try {
    if (-not (Get-WindowsFeature Windows-Server-Backup).Installed) {
        Install-WindowsFeature -Name Windows-Server-Backup -IncludeManagementTools
    }

    # Engangs system state-backup til volum E: (NAS/dedikert disk)
    wbadmin start systemstatebackup -backupTarget:E: -quiet

    # Aktiver AD Recycle Bin hvis den ikke allerede er på (idempotent)
    $rb = Get-ADOptionalFeature -Filter 'Name -like "Recycle Bin Feature"'
    if (-not $rb.EnabledScopes) {
        Enable-ADOptionalFeature -Identity 'Recycle Bin Feature' `
            -Scope ForestOrConfigurationSet -Target 'ad.vardeholm.no' -Confirm:$false
        Write-Host "AD Recycle Bin aktivert."
    } else {
        Write-Host "AD Recycle Bin allerede aktivert."
    }
} catch {
    Write-Error "Feil i backup-oppsett: $_"
}
#endregion

Write-Host "Boot 3 ferdig - server, DHCP, AD-struktur, fildeling, print, GPO og backup er satt opp."

# Gjenopprett en slettet AD-bruker (eksempel):
# Get-ADObject -Filter 'isDeleted -eq $true -and Name -like "*Kari*"' `
#   -IncludeDeletedObjects | Restore-ADObject
