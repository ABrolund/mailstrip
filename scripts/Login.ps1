# =============================================================================
# Login.ps1
# -----------------------------------------------------------------------------
# Interaktive Anmeldung (Device-Code). Wird vom Installer und über das Menü
# "Anmelden bei Microsoft …" (Login.command) aufgerufen.
# Danach wird die Managerliste geholt und der Checker neu gestartet, damit
# er das frische Token sofort verwendet.
# =============================================================================

. (Join-Path $PSScriptRoot 'MailStrip-Common.ps1')

# Bestehende Sitzung verwerfen, damit wirklich neu angemeldet wird.
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

Write-Host 'Anmeldung bei Microsoft Graph (Code im Browser eingeben) ...'
if (-not (Connect-MailStrip)) { Write-Host 'Anmeldung fehlgeschlagen.' -ForegroundColor Red; exit 1 }

# Managerliste direkt aktualisieren und kurz anzeigen (Kontrolle).
$config = Get-MailStripConfig
Update-ManagerList $config
$m = Read-ManagerList $config
Write-Host "Line Manager (gelb): $($m.LineManager)"
Write-Host "Management (rot):    $($m.Red.Count) Personen"

# Checker neu starten (Fehler ignorieren, falls er noch nicht installiert ist).
$uid = (& id -u)
& launchctl kickstart -k "gui/$uid/$CheckerLabel" 2>$null
Write-Host 'Fertig.' -ForegroundColor Green
