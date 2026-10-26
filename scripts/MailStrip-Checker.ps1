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
#   4. alle auslösenden Mails mit Grund in state.json schreiben
#      -> die Swift-App zeigt Balken + Liste; leer = kein Balken
#   5. intervalSeconds warten (Standard 60 s)
# =============================================================================

. (Join-Path $PSScriptRoot 'MailStrip-Common.ps1')

# Ermittelt alle ungelesenen Mails, die eine Kategorie auslösen.
# Rückgabe: Liste von Einträgen (id, category, name, address, subject,
#           received, webLink, reason).
# Ordnertabelle (siehe Get-FolderMap) mit Zeitpunkt und verwendeter
# Ignorierliste. Wird neu gebaut, wenn sie zu alt ist, sich ignoreFolders
# geändert hat oder eine Mail in einem unbekannten (neuen) Ordner liegt.
# $script: = gilt für das ganze Skript und bleibt zwischen Durchläufen erhalten.
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

function Get-InboxItems($Config, $Managers) {
    # Angemeldetes Konto = eigenes Postfach.
    $user = (Get-MgContext).Account

    # Nur aktuelle ungelesene Mails (lookbackHours Arbeitsstunden, Standard 24).
    # Ältere ungelesene Mails (z. B. Newsletter von vor Wochen) lösen sonst
    # dauerhaft Alarm aus. Wochenenden werden übersprungen.
    $since  = ConvertTo-IsoUtc (Get-LookbackStart $Config)
    $filter = "isRead eq false and receivedDateTime ge $since"
    # /me/messages durchsucht ALLE Ordner auf einmal (ein Aufruf statt einer
    # pro Ordner). Ausgeschlossene Ordner werden danach per parentFolderId
    # herausgefiltert. -All holt bei Bedarf weitere Seiten.
    $msgs = Get-MgUserMessage -UserId $user -Filter $filter -All -PageSize 100 `
            -Property 'id,from,subject,receivedDateTime,webLink,parentFolderId' -ErrorAction Stop

    # Ordnertabelle holen (meist aus dem Zwischenspeicher, also ohne Graph-Aufruf).
    $folders = Get-CurrentFolderMap $Config
    # Neuer Ordner seit dem letzten Aufbau? Dann Tabelle einmal neu laden.
    # (z. B. gerade per Regel angelegter Ordner)
    if ($msgs | Where-Object { -not $folders.ContainsKey($_.ParentFolderId) }) {
        $folders = Get-CurrentFolderMap $Config -Force
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $msgs) {
        # Absenderadresse klein schreiben, damit der Vergleich eindeutig ist.
        $addr = "$($m.From.EmailAddress.Address)".ToLower()
        if (-not $addr) { continue }               # z. B. Systemmails ohne Absender

        # Ordner prüfen. Unbekannter Ordner (auch nach Neuaufbau) -> sicherheitshalber werten.
        # $fi = Eintrag aus der Ordnertabelle (Path, Excluded) oder $null.
        $fi = $folders[$m.ParentFolderId]
        if ($fi -and $fi.Excluded) { continue }
        $folderPath = if ($fi) { $fi.Path } else { '?' }
        $domain = $addr.Split('@')[-1]

        # Reihenfolge wichtig: Line Manager zuerst, sonst würde ein passender
        # Titel (z. B. "Head of") ihn rot statt gelb machen.
        $cat = $null; $reason = ''
        if ($Managers.LineManager -and $addr -eq $Managers.LineManager) {
            $cat = 'linemanager'; $reason = 'Line Manager'
        } elseif ($Managers.Red.ContainsKey($addr)) {
            $cat = 'management';  $reason = $Managers.Red[$addr]
        } elseif ($hit = Find-Domain $domain $Config.customerDomains) {
            $cat = 'customer';    $reason = "Kunden-Domain $hit"
        }
        if (-not $cat) { continue }                # nicht relevant -> ignorieren

        # Eintrag für state.json (Feldnamen = MailItem in MailStrip.swift).
        $items.Add([ordered]@{
            id       = $m.Id
            category = $cat
            name     = $m.From.EmailAddress.Name
            address  = $addr
            subject  = $m.Subject
            received = ConvertTo-IsoUtc $m.ReceivedDateTime
            webLink  = $m.WebLink
            reason   = $reason
            folder   = $folderPath
        })
    }
    # Komma verhindert, dass PowerShell die Liste beim Zurückgeben "auspackt".
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
        # 1. Anmelden (Menüleiste zeigt ⚠︎, solange das nicht klappt)
        if (-not $connected) {
            Write-StripStatus 'auth' @() 'Anmeldung läuft'
            $connected = Connect-MailStrip
        }

        # An freien Tagen (Standard: Sa/So) nicht prüfen -> kein Balken.
        # Status "ok" mit leerer Liste, damit die App nicht "veraltet" meldet.
        if (-not (Test-WorkDay $config (Get-Date))) {
            Write-StripStatus 'ok' @() 'Kein Arbeitstag'
            if ($lastSig -ne 'off') { Write-Log 'Kein Arbeitstag – Prüfung pausiert.'; $lastSig = 'off' }
            Start-Sleep -Seconds $config.intervalSeconds
            continue
        }

        # 2. Managerliste wöchentlich (oder auf Anforderung aus dem Menü)
        if (Test-ManagerListDue $config) { Update-ManagerList $config }
        $managers = Read-ManagerList $config

        # 3. + 4. Posteingang prüfen und Ergebnis schreiben
        # Leere Liste ist ein gültiges Ergebnis -> Balken verschwindet.
        $items = Get-InboxItems $config $managers
        Write-StripStatus 'ok' $items

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
    # 5. Warten – auch nach Fehlern, damit Graph nicht im Sekundentakt abgefragt wird.
    Start-Sleep -Seconds $config.intervalSeconds
}
