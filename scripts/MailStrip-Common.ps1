# =============================================================================
# MailStrip-Common.ps1
# -----------------------------------------------------------------------------
# Gemeinsame Funktionen für Checker und Login. Wird per Dot-Sourcing geladen:
#     . (Join-Path $PSScriptRoot 'MailStrip-Common.ps1')
# Enthält: Pfade, Logging, Status schreiben, Config lesen, Graph-Anmeldung,
#          Managerliste laden/aktualisieren.
# =============================================================================

# --- Pfade -------------------------------------------------------------------
# Alles liegt unter ~/Library/Application Support/MailStrip (keine Admin-Rechte,
# keine Probleme mit macOS-Datenschutz wie bei ~/Documents).
$script:AppDir      = Join-Path $HOME 'Library/Application Support/MailStrip'
$script:StateFile   = Join-Path $AppDir 'state.json'       # wird von der Swift-App gelesen
$script:ConfigFile  = Join-Path $AppDir 'config.json'      # deine Einstellungen
$script:ManagerFile = Join-Path $AppDir 'management.json'  # Cache der Managerliste
$script:RefreshFlag = Join-Path $AppDir 'refresh-now'      # Signal aus dem Menü

# Benötigte Graph-Rechte: Mails lesen + Verzeichnis (Manager, Jobtitel) lesen.
$script:Scopes = @('Mail.Read', 'User.Read.All')

# Label des Checker-Dienstes in launchd (für Neustart nach Anmeldung).
$script:CheckerLabel = 'com.andreasbrolund.mailstrip.checker'

# --- Logging -----------------------------------------------------------------
# launchd leitet die Ausgabe in ~/Library/Logs/MailStrip/checker.log um.
function Write-Log([string]$Message) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
}

# --- Zeit als ISO-8601 in UTC -------------------------------------------------
# Format, das die Swift-App (ISO8601DateFormatter) direkt versteht.
function ConvertTo-IsoUtc($Date) {
    if (-not $Date) { return '' }
    return ([datetime]$Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

# --- Status für den Balken schreiben -----------------------------------------
# $Status: 'ok' (Prüfung erfolgreich) oder 'auth' (Anmeldung nötig).
# $Items:  Liste der auslösenden Mails (leer = kein Balken).
# Erst in eine temporäre Datei, dann umbenennen -> die App liest nie eine
# halb geschriebene Datei.
# Format siehe StatusFile/MailItem in MailStrip.swift.
function Write-StripStatus([string]$Status, $Items, [string]$Message = '') {
    if ($null -eq $Items) { $Items = @() }   # @($null) wäre ein Array mit einem Element
    $obj = [ordered]@{
        status  = $Status
        updated = ConvertTo-IsoUtc (Get-Date)
        message = $Message
        items   = @($Items)
    }
    $tmp = "$StateFile.tmp"
    # -Depth 5: verschachtelte Einträge vollständig schreiben.
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $StateFile -Force
}

# --- Config ------------------------------------------------------------------
# Wird bei jedem Durchlauf neu gelesen -> Änderungen wirken ohne Neustart.
function Get-MailStripConfig {
    Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
}

# Prüft, ob eine Domain zu einer Liste passt (Subdomains zählen mit).
# Gibt die passende Listen-Domain zurück oder $null.
function Find-Domain([string]$Domain, $List) {
    $List | Where-Object { $Domain -eq $_ -or $Domain.EndsWith(".$_") } | Select-Object -First 1
}

# --- Anmeldung bei Microsoft Graph ------------------------------------------
# -ContextScope CurrentUser speichert das Token im Benutzer-Cache, damit es
# nach einem Neustart wiederverwendet werden kann. Ist das Token gültig, kehrt
# Connect-MgGraph sofort zurück. Ist es abgelaufen, wartet der Device-Code-
# Flow (Code steht im Log) – Anmelden geht bequemer über das Menü.
function Connect-MailStrip {
    # Get-MgContext liefert die aktuelle Sitzung dieses Prozesses (oder nichts).
    $ctx = Get-MgContext
    if ($ctx -and -not ($Scopes | Where-Object { $ctx.Scopes -notcontains $_ })) { return $true }

    # Kein gültiger Kontext -> anmelden (aus Cache oder per Device-Code).
    Connect-MgGraph -Scopes $Scopes -ContextScope CurrentUser -UseDeviceAuthentication -NoWelcome -ErrorAction Stop
    $ctx = Get-MgContext
    Write-Log "Angemeldet als $($ctx.Account)"
    return [bool]$ctx
}

# --- Managerliste ------------------------------------------------------------
# Ist eine Aktualisierung fällig? Ja, wenn die Datei fehlt, älter als
# managerListRefreshDays ist oder im Menü "jetzt aktualisieren" geklickt wurde.
function Test-ManagerListDue($Config) {
    if (Test-Path $RefreshFlag) { Remove-Item $RefreshFlag -Force; return $true }
    if (-not (Test-Path $ManagerFile)) { return $true }
    $age = (Get-Date) - (Get-Item $ManagerFile).LastWriteTime
    return $age.TotalDays -ge $Config.managerListRefreshDays
}

# Holt (1) deine Managementkette und (2) alle Personen mit Management-Titel
# aus dem Organisationsverzeichnis und speichert sie in management.json.
function Update-ManagerList($Config) {
    Write-Log 'Aktualisiere Managerliste ...'
    # Nur diese Felder laden – spart Zeit bei vielen Benutzern.
    $props = 'id,displayName,mail,jobTitle,department'
    $me    = Get-MgUser -UserId (Get-MgContext).Account -Property $props

    # (1) Kette nach oben. Abbruch an der Spitze: Der CEO ist im Verzeichnis
    #     sein eigener Manager, sonst gäbe es eine Endlosschleife.
    # $seen merkt sich bereits besuchte Personen (Schutz vor Schleifen).
    $chain = @()
    $seen  = @{ $me.Id = $true }
    $id    = $me.Id
    for ($i = 1; $i -le $Config.managerChainMaxLevels; $i++) {
        try { $mgr = Get-MgUserManager -UserId $id -ErrorAction Stop } catch { break }
        if ($seen.ContainsKey($mgr.Id)) { break }
        $seen[$mgr.Id] = $true
        $u = Get-MgUser -UserId $mgr.Id -Property $props
        $chain += [pscustomobject]@{ level = $i; name = $u.DisplayName; mail = "$($u.Mail)".ToLower(); title = $u.JobTitle }
        $id = $mgr.Id
    }

    # (2) Alle aktiven Konten laden und nach Jobtitel filtern.
    #     -All blättert automatisch durch alle Seiten.
    #     Nur interne Domains, damit Kunden-Titel ("Director" bei Philips) nicht rot werden.
    $all  = Get-MgUser -All -Filter 'accountEnabled eq true' -Property $props -PageSize 999
    $byTitle = foreach ($u in $all) {
        $mail = "$($u.Mail)".ToLower()
        if (-not $mail) { continue }
        $internal = Find-Domain $mail.Split('@')[-1] $Config.internalDomains
        $title    = "$($u.JobTitle)"
        $isMgmt   = $Config.managementTitlePatterns | Where-Object { $title -match $_ }
        if ($internal -and $isMgmt) { [pscustomobject]@{ name = $u.DisplayName; mail = $mail; title = $title } }
    }

    # Schutz: Wenn gar nichts gefunden wurde, alte Liste behalten statt leeren.
    if ($chain.Count -eq 0 -and @($byTitle).Count -eq 0) {
        Write-Log 'WARNUNG: Keine Manager gefunden – alte Liste bleibt erhalten.'
        return
    }

    # Atomar speichern (erst tmp, dann umbenennen). Zeitstempel hilft bei der Fehlersuche.
    $data = [pscustomobject]@{ updated = (Get-Date).ToString('s'); chain = $chain; byTitle = @($byTitle) }
    $tmp  = "$ManagerFile.tmp"
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $ManagerFile -Force
    Write-Log "Managerliste: $($chain.Count) in deiner Linie, $(@($byTitle).Count) per Titel."
}

# Liest management.json und baut daraus die Gruppen für die Farben:
#   LineManager = Ebene 1 der Kette                                  -> gelb
#   Red         = Wörterbuch Adresse -> Grund (Ebene 2+, Titel,
#                 extraManagementAddresses)                          -> rot
# Der Grund wird später im Menü angezeigt ("warum ist das rot?").
function Read-ManagerList($Config) {
    $data = Get-Content -Path $ManagerFile -Raw | ConvertFrom-Json
    # Ebene 1 der Kette = direkter Vorgesetzter.
    $line = ($data.chain | Where-Object level -eq 1 | Select-Object -First 1).mail
    $red  = [System.Collections.Generic.Dictionary[string,string]]::new()

    foreach ($c in @($data.chain | Where-Object level -gt 1)) {
        if ($c.mail) { $red[$c.mail] = "Linie Ebene $($c.level): $($c.title)" }
    }
    foreach ($b in @($data.byTitle)) {
        # Linien-Grund hat Vorrang, weil er aussagekräftiger ist.
        if ($b.mail -and -not $red.ContainsKey($b.mail)) { $red[$b.mail] = "Titel: $($b.title)" }
    }
    foreach ($a in @($Config.extraManagementAddresses)) {
        if ($a) { $red["$a".ToLower()] = 'Manuell in config.json' }
    }
    # Line Manager bleibt gelb, auch wenn sein Titel passt.
    if ($line) { [void]$red.Remove($line) }
    # Rückgabe als Hashtable an den Checker.
    return @{ LineManager = $line; Red = $red }
}
