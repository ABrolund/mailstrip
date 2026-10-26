# =============================================================================
# MailStrip-Checker.ps1
# -----------------------------------------------------------------------------
# Läuft dauerhaft im Hintergrund (gestartet von launchd beim Anmelden).
# Pro Durchlauf:
#   1. bei Bedarf bei Microsoft Graph anmelden
#   2. einmal pro Woche die Managerliste aktualisieren
#   3. nur an Arbeitstagen: ungelesene Mails der letzten 24 Arbeitsstunden
#      prüfen (am Wochenende kein Balken)
#   4. alle auslösenden Mails mit Grund in state.json schreiben
#      -> die Swift-App zeigt Balken + Liste; leer = kein Balken
#   5. intervalSeconds warten (Standard 60 s)
# =============================================================================

. (Join-Path $PSScriptRoot 'MailStrip-Common.ps1')

# Ermittelt alle ungelesenen Mails, die eine Kategorie auslösen.
# Rückgabe: Liste von Einträgen (id, category, name, address, subject,
#           received, webLink, reason).
function Get-InboxItems($Config, $Managers) {
    # Angemeldetes Konto = eigenes Postfach.
    $user = (Get-MgContext).Account

    # Nur aktuelle ungelesene Mails (lookbackHours Arbeitsstunden, Standard 24).
    # Ältere ungelesene Mails (z. B. Newsletter von vor Wochen) lösen sonst
    # dauerhaft Alarm aus. Wochenenden werden übersprungen.
    $since  = ConvertTo-IsoUtc (Get-LookbackStart $Config)
    $filter = "isRead eq false and receivedDateTime ge $since"
    # Nur benötigte Felder laden – schnell und datensparsam.
    $msgs = Get-MgUserMailFolderMessage -UserId $user -MailFolderId 'inbox' -Filter $filter -Top 100 `
            -Property 'id,from,subject,receivedDateTime,webLink' -ErrorAction Stop

    # Ergebnisliste. List statt Array, weil Hinzufügen günstiger ist.
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $msgs) {
        # Absenderadresse klein schreiben, damit der Vergleich eindeutig ist.
        $addr = "$($m.From.EmailAddress.Address)".ToLower()
        if (-not $addr) { continue }               # z. B. Systemmails ohne Absender
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
            foreach ($it in $items) { Write-Log "  [$($it.category)] $($it.address) – $($it.reason)" }
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
