# =============================================================================
# MailStrip-Checker.ps1
# -----------------------------------------------------------------------------
# Läuft dauerhaft im Hintergrund (gestartet von launchd beim Anmelden).
# Pro Durchlauf:
#   1. bei Bedarf bei Microsoft Graph anmelden
#   2. einmal pro Woche die Managerliste aktualisieren
#   3. nur an Arbeitstagen: ungelesene Mails der letzten 24 Arbeitsstunden
#      in ALLEN Ordnern prüfen – außer Gesendet, Gelöscht, Junk, Entwürfe,
#      Postausgang und den Ordnern aus ignoreFolders (am Wochenende kein Balken)
#   4. jede Mail einstufen: Line Manager (gelb), Management (rot),
#      @-Erwähnung (türkis), Kunde (grün)
#   5. alle Treffer mit Grund in state.json schreiben
#      -> die Swift-App zeigt Balken + Liste; leer = kein Balken
#   6. intervalSeconds warten (Standard 60 s)
# =============================================================================

. (Join-Path $PSScriptRoot 'MailStrip-Common.ps1')

# --- Ordnertabelle (Zwischenspeicher) -----------------------------------------
# $script: = gilt für das ganze Skript und bleibt zwischen Durchläufen erhalten.
# Wird neu gebaut, wenn sie zu alt ist, sich ignoreFolders geändert hat oder
# eine Mail in einem unbekannten (neuen) Ordner liegt.
$script:FolderMap     = $null
$script:FolderMapTime = [datetime]::MinValue
$script:FolderMapKey  = ''

# -Force erzwingt den Neuaufbau (z. B. bei unbekanntem Ordner).
# $key erkennt Änderungen an ignoreFolders ohne Neustart.
function Get-CurrentFolderMap($Config, [switch]$Force) {
    $key = (@($Config.ignoreFolders) -join '|').ToLower()
    $age = ((Get-Date) - $script:FolderMapTime).TotalMinutes
    if ($Force -or -not $script:FolderMap -or $key -ne $script:FolderMapKey -or
        $age -ge [int]$Config.folderMapRefreshMinutes) {
        $script:FolderMap     = Get-FolderMap $Config
        $script:FolderMapTime = Get-Date
        $script:FolderMapKey  = $key
    }
    return $script:FolderMap
}

# --- Eigene Identität (für Erwähnungen) ---------------------------------------
# Eigene Adresse: eigene Mails, in denen man sich selbst erwähnt, zählen nicht.
# Namen für die Ersatzerkennung: aus config.json (mentionNames) oder, wenn
# leer, automatisch Anzeigename + Vorname aus dem Verzeichnis.
$script:Me = $null

function Get-MyIdentity($Config) {
    if (-not $script:Me) {
        $u = Get-MgUser -UserId (Get-MgContext).Account -Property 'mail,displayName,givenName'
        $script:Me = @{ Mail = "$($u.Mail)".ToLower(); DisplayName = $u.DisplayName; GivenName = $u.GivenName }
    }
    # Namen bei jedem Aufruf neu bestimmen -> Änderungen an config.json wirken sofort.
    $names = @($Config.mentionNames | Where-Object { $_ })
    if (-not $names) { $names = @($script:Me.DisplayName, $script:Me.GivenName) | Where-Object { $_ } }
    return @{ Mail = $script:Me.Mail; Names = $names }
}

# --- Mails von Graph laden ----------------------------------------------------
# Liefert eine Liste von Hashtables mit den Feldern der Graph-Antwort.
# Versuch 1: Beta-Schnittstelle mit "mentionsPreview" -> zuverlässige Erkennung,
#            ob man in der Mail per @ erwähnt wurde.
# Versuch 2 (wenn Beta nicht geht): v1.0 mit "bodyPreview" (erste ca. 255
#            Zeichen des Textes) -> Ersatzerkennung über "@Name".
# $script:UseBeta merkt sich das Ergebnis, damit nicht jedes Mal gescheitert wird.
$script:UseBeta = $true

function Get-UnreadMessages([string]$Filter) {
    # Nur benötigte Felder laden – schnell und datensparsam.
    $fields = 'id,from,subject,receivedDateTime,webLink,parentFolderId,bodyPreview'
    $query  = "`$filter=$([uri]::EscapeDataString($Filter))&`$top=100"

    if ($script:UseBeta) {
        try {
            return Read-AllPages "https://graph.microsoft.com/beta/me/messages?$query&`$select=$fields,mentionsPreview"
        } catch {
            # Einmalig ins Log und dauerhaft auf v1.0 umschalten.
            Write-Log "Hinweis: Beta-Schnittstelle nicht nutzbar ($($_.Exception.Message)) – nutze Ersatzerkennung."
            $script:UseBeta = $false
        }
    }
    return Read-AllPages "https://graph.microsoft.com/v1.0/me/messages?$query&`$select=$fields"
}

# Folgt "@odata.nextLink", bis alle Seiten geladen sind.
# /me/messages durchsucht ALLE Ordner auf einmal (ein Aufruf statt einer pro Ordner).
function Read-AllPages([string]$Url) {
    $all = [System.Collections.Generic.List[object]]::new()
    while ($Url) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $Url -ErrorAction Stop
        foreach ($v in $r.value) { $all.Add($v) }
        $Url = $r.'@odata.nextLink'
    }
    # Komma verhindert, dass PowerShell die Liste beim Zurückgeben "auspackt".
    return ,$all
}

# Wurde ich in dieser Mail erwähnt?
# Beta: mentionsPreview.isMentioned (von Outlook gesetzt, wenn ein @-Mention
#       mit meinem Namen eingefügt wurde).
# Ersatz: "@<Name>" kommt im Textanfang vor. Erkennt nur Erwähnungen in den
#       ersten ca. 255 Zeichen – weiter unten im Text nicht.
function Test-Mentioned($Message, $Identity) {
    if ($Message.ContainsKey('mentionsPreview') -and $Message.mentionsPreview) {
        return [bool]$Message.mentionsPreview.isMentioned
    }
    $text = "$($Message.bodyPreview)"
    foreach ($n in $Identity.Names) {
        # [regex]::Escape: Sonderzeichen im Namen wörtlich nehmen.
        if ($text -match ('@' + [regex]::Escape($n))) { return $true }
    }
    return $false
}

# --- Einstufung ---------------------------------------------------------------
# Ermittelt alle ungelesenen Mails, die eine Kategorie auslösen.
# Rückgabe: Liste von Einträgen (id, category, name, address, subject,
#           received, webLink, reason, folder) – Feldnamen = MailItem in Swift.
function Get-InboxItems($Config, $Managers) {
    # Nur aktuelle ungelesene Mails (lookbackHours Arbeitsstunden, Standard 24).
    # Ältere ungelesene Mails (z. B. Newsletter von vor Wochen) lösen sonst
    # dauerhaft Alarm aus. Wochenenden werden übersprungen.
    $since  = ConvertTo-IsoUtc (Get-LookbackStart $Config)
    $msgs   = Get-UnreadMessages "isRead eq false and receivedDateTime ge $since"
    $me     = Get-MyIdentity $Config

    # Ordnertabelle holen (meist aus dem Zwischenspeicher, also ohne Graph-Aufruf).
    $folders = Get-CurrentFolderMap $Config
    # Neuer Ordner seit dem letzten Aufbau (z. B. gerade per Regel angelegt)?
    # Dann Tabelle einmal neu laden.
    if ($msgs | Where-Object { -not $folders.ContainsKey($_.parentFolderId) }) {
        $folders = Get-CurrentFolderMap $Config -Force
    }

    # Ergebnisliste. List statt Array, weil Hinzufügen günstiger ist.
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $msgs) {
        # Absenderadresse klein schreiben, damit der Vergleich eindeutig ist.
        $addr = "$($m.from.emailAddress.address)".ToLower()
        if (-not $addr) { continue }               # z. B. Systemmails ohne Absender
        $domain = $addr.Split('@')[-1]

        # Ordner prüfen. Unbekannter Ordner (auch nach Neuaufbau) -> sicherheitshalber werten.
        # $fi = Eintrag aus der Ordnertabelle (Path, Excluded) oder $null.
        $fi = $folders[$m.parentFolderId]
        if ($fi -and $fi.Excluded) { continue }
        $folderPath = if ($fi) { $fi.Path } else { '?' }

        # Reihenfolge = Vorrang, falls mehreres zutrifft:
        #   1. Line Manager (gelb) – zuerst, sonst würde ein passender Titel
        #      (z. B. "Head of") ihn rot machen.
        #   2. Management (rot)
        #   3. @-Erwähnung (türkis) – nicht bei eigenen Mails.
        #   4. Kunde (grün)
        # Erwähnt dich ein Manager, bleibt die Mail also gelb bzw. rot.
        $cat = $null; $reason = ''
        if ($Managers.LineManager -and $addr -eq $Managers.LineManager) {
            $cat = 'linemanager'; $reason = 'Line Manager'
        } elseif ($Managers.Red.ContainsKey($addr)) {
            $cat = 'management';  $reason = $Managers.Red[$addr]
        } elseif ($Config.mentionsEnabled -and $addr -ne $me.Mail -and (Test-Mentioned $m $me)) {
            $cat = 'mention';     $reason = '@-Erwähnung'
        } elseif ($hit = Find-Domain $domain $Config.customerDomains) {
            $cat = 'customer';    $reason = "Kunden-Domain $hit"
        }
        if (-not $cat) { continue }                # nicht relevant -> ignorieren

        # Eintrag für state.json (Feldnamen = MailItem in MailStrip.swift).
        $items.Add([ordered]@{
            id       = $m.id
            category = $cat
            name     = $m.from.emailAddress.name
            address  = $addr
            subject  = $m.subject
            received = ConvertTo-IsoUtc $m.receivedDateTime
            webLink  = $m.webLink
            reason   = $reason
            folder   = $folderPath
        })
    }
    return ,$items
}

# --- Hauptschleife -----------------------------------------------------------
# $connected: ob in diesem Prozess schon eine Graph-Sitzung besteht.
# $lastSig:   Signatur der letzten Trefferliste, nur für sparsames Logging.
Write-Log 'MailStrip-Checker gestartet.'
# Startwerte.
$connected = $false
$lastSig   = $null

# Endlosschleife; beendet wird der Prozess nur durch launchd/uninstall.
while ($true) {
    $config = Get-MailStripConfig          # jedes Mal neu -> Änderungen sofort aktiv
    try {
        # An freien Tagen (Standard: Sa/So) nicht prüfen -> kein Balken.
        # Status "ok" mit leerer Liste, damit die App nicht "veraltet" meldet.
        if (-not (Test-WorkDay $config (Get-Date))) {
            Write-StripStatus 'ok' @() 'Kein Arbeitstag'
            if ($lastSig -ne 'off') { Write-Log 'Kein Arbeitstag – Prüfung pausiert.'; $lastSig = 'off' }
            Start-Sleep -Seconds $config.intervalSeconds
            continue
        }

        # 1. Anmelden (Menüleiste zeigt ⚠︎, solange das nicht klappt)
        if (-not $connected) {
            Write-StripStatus 'auth' @() 'Anmeldung läuft'
            $connected = Connect-MailStrip
        }

        # 2. Managerliste wöchentlich (oder auf Anforderung aus dem Menü)
        if (Test-ManagerListDue $config) { Update-ManagerList $config }
        $managers = Read-ManagerList $config

        # 3.–5. Mails prüfen und Ergebnis schreiben.
        # Leere Liste ist ein gültiges Ergebnis -> Balken verschwindet.
        $items = Get-InboxItems $config $managers
        # Betriebsdaten für den Statusbereich im Menü. Die Ordnertabelle liegt
        # bereits im Cache, daher entsteht hier kein zusätzlicher Graph-Aufruf.
        $folderMap = Get-CurrentFolderMap $config
        $info = @{
            MonitoredFolders = @($folderMap.Values | Where-Object { -not $_.Excluded }).Count
            ManagementCount  = $managers.Red.Count
            LineManager      = $managers.LineManager
        }
        Write-StripStatus 'ok' $items '' $info

        # Bei Änderung jeden Treffer mit Grund loggen -> Fehlalarme nachvollziehbar.
        # Signatur = alle Mail-IDs; ändert sich nur bei neuen/gelesenen Mails.
        $sig = ($items | ForEach-Object { $_.id }) -join ','
        if ($sig -ne $lastSig) {
            Write-Log "Treffer: $($items.Count)"
            foreach ($it in $items) { Write-Log "  [$($it.category)] $($it.address) – $($it.reason) – Ordner: $($it.folder)" }
            $lastSig = $sig
        }
    }
    catch {
        Write-Log "FEHLER: $($_.Exception.Message)"
        # Bei Token-/Anmeldefehlern neu anmelden. Andere Fehler (z. B. kurz kein
        # Netz) lassen den letzten Stand stehen; die App warnt nach 5 min.
        if ("$_" -match 'token|auth|401|403|login|credential') {
            $connected = $false
            Write-StripStatus 'auth' @() "$($_.Exception.Message)"
            $lastSig = $null
        }
    }
    # 6. Warten – auch nach Fehlern, damit Graph nicht im Sekundentakt abgefragt wird.
    Start-Sleep -Seconds $config.intervalSeconds
}
