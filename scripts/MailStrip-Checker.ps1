# =============================================================================
# MailStrip-Checker.ps1
# -----------------------------------------------------------------------------
# Läuft dauerhaft im Hintergrund (gestartet von launchd beim Anmelden).
# Pro Durchlauf:
#   1. bei Bedarf bei Microsoft Graph anmelden
#   2. einmal pro Woche die Managerliste aktualisieren
#   3. ungelesene Mails im Posteingang prüfen
#   4. Ergebnis in state.txt schreiben -> die Swift-App färbt den Balken
#   5. intervalSeconds warten (Standard 60 s)
# =============================================================================

. (Join-Path $PSScriptRoot 'MailStrip-Common.ps1')

# Rangfolge, falls mehrere wichtige Mails gleichzeitig ungelesen sind:
# rot schlägt gelb, gelb schlägt grün, grün schlägt blau.
$Rank = @{ idle = 0; customer = 1; linemanager = 2; management = 3 }

# Ermittelt aus den ungelesenen Mails den "höchsten" Zustand.
function Get-InboxState($Config, $Managers) {
    # Angemeldetes Konto = eigenes Postfach.
    $user = (Get-MgContext).Account
    # Nur Absender laden (-Property from) – schnell und datensparsam.
    $msgs = Get-MgUserMailFolderMessage -UserId $user -MailFolderId 'inbox' `
            -Filter 'isRead eq false' -Top 100 -Property 'from' -ErrorAction Stop

    # Start mit blau; jede wichtigere Mail hebt den Zustand an.
    $state = 'idle'
    foreach ($m in $msgs) {
        # Absenderadresse klein schreiben, damit der Vergleich eindeutig ist.
        $addr   = "$($m.From.EmailAddress.Address)".ToLower()
        $domain = $addr.Split('@')[-1]

        # Reihenfolge wichtig: Line Manager zuerst, sonst würde ein passender
        # Titel (z. B. "Head of") ihn rot statt gelb machen.
        $s = 'idle'
        if ($Managers.LineManager -and $addr -eq $Managers.LineManager) { $s = 'linemanager' }
        elseif ($Managers.Red.Contains($addr))                          { $s = 'management' }
        elseif ($Config.customerDomains | Where-Object { $domain -eq $_ -or $domain.EndsWith(".$_") }) { $s = 'customer' }

        if ($Rank[$s] -gt $Rank[$state]) { $state = $s }
        if ($state -eq 'management') { break }   # höher geht nicht
    }
    return $state
}

# --- Hauptschleife ---------------------------------------------------------
# $connected: ob in diesem Prozess schon eine Graph-Sitzung besteht.
# $lastState: letzter geschriebener Zustand, nur für sparsames Logging.
Write-Log 'MailStrip-Checker gestartet.'
$connected = $false
$lastState = ''

while ($true) {
    $config = Get-MailStripConfig          # jedes Mal neu -> Änderungen sofort aktiv
    try {
        # 1. Anmelden (grau, solange das nicht klappt)
        if (-not $connected) {
            Set-StripState 'auth'
            $connected = Connect-MailStrip
        }

        # 2. Managerliste wöchentlich (oder auf Anforderung aus dem Menü)
        if (Test-ManagerListDue $config) { Update-ManagerList $config }
        $managers = Read-ManagerList $config

        # 3. + 4. Posteingang prüfen und Zustand schreiben
        $state = Get-InboxState $config $managers
        Set-StripState $state

        # Nur Zustandswechsel loggen, damit das Log klein bleibt.
        if ($state -ne $lastState) { Write-Log "Zustand: $state"; $lastState = $state }
    }
    catch {
        Write-Log "FEHLER: $($_.Exception.Message)"
        # Bei Token-/Anmeldefehlern beim nächsten Durchlauf neu anmelden.
        if ("$_" -match 'token|auth|401|403|login|credential') {
            $connected = $false
            Set-StripState 'auth'
            $lastState = 'auth'
        }
    }
    # 5. Warten
    # Auch nach Fehlern warten, damit Graph nicht im Sekundentakt abgefragt wird.
    Start-Sleep -Seconds $config.intervalSeconds
}
