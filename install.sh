#!/bin/bash
# =============================================================================
# install.sh – richtet MailStrip komplett ein (ohne Admin-Rechte)
# -----------------------------------------------------------------------------
# Ablauf:
#   1. Voraussetzungen prüfen (swiftc, pwsh, Microsoft.Graph-Module)
#   2. alte Instanzen stoppen
#   3. Dateien nach ~/Library/Application Support/MailStrip kopieren
#   4. Swift-App bauen
#   5. bei Microsoft anmelden + Managerliste holen
#   6. zwei LaunchAgents anlegen -> Start automatisch nach jedem Login/Reboot
# Erneut ausführen ist gefahrlos (z. B. nach einem Update aus GitHub).
# =============================================================================
set -euo pipefail   # bei jedem Fehler abbrechen

# --- Pfade und Namen ---------------------------------------------------------
# REPO_DIR: von hier werden Quellen gelesen (dein Git-Checkout).
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Library/Application Support/MailStrip"     # Programm + Daten
LOG_DIR="$HOME/Library/Logs/MailStrip"                    # Logs (Konsole-App)
AGENT_DIR="$HOME/Library/LaunchAgents"                    # Autostart pro Benutzer
GUI="gui/$(id -u)"                                        # launchd-Domäne des Benutzers
LABEL_STRIP="com.andreasbrolund.mailstrip"                # Balken (Swift)
LABEL_CHECK="com.andreasbrolund.mailstrip.checker"        # Mail-Prüfung (PowerShell)

# Hilfsfunktion: gibt eine Überschrift pro Schritt aus.
step() { echo; echo "==> $*"; }

# --- 1. Voraussetzungen ------------------------------------------------------
step "Prüfe Voraussetzungen"
# swiftc kommt aus den Xcode Command Line Tools.
command -v swiftc >/dev/null || { echo "swiftc fehlt: xcode-select --install"; exit 1; }
# Pfad zu pwsh merken – launchd kennt PATH nicht, daher absolut eintragen.
PWSH="$(command -v pwsh || true)"
# Ohne PowerShell kann der Checker nicht laufen.
[ -n "$PWSH" ] || { echo "PowerShell (pwsh) fehlt."; exit 1; }
echo "swiftc: $(command -v swiftc)"
echo "pwsh:   $PWSH"

# Nur die drei benötigten Graph-Module; fehlende werden installiert.
# -Force unterdrückt die Rückfrage "Untrusted repository" (PSGallery).
# -Scope CurrentUser -> Installation ohne Admin-Rechte.
"$PWSH" -NoLogo -NoProfile -Command '
  foreach ($m in "Microsoft.Graph.Authentication","Microsoft.Graph.Users","Microsoft.Graph.Mail") {
    if (-not (Get-Module -ListAvailable -Name $m)) {
      Write-Host "Installiere $m ..."
      Install-Module $m -Scope CurrentUser -Force -AllowClobber
    } else { Write-Host "$m vorhanden" }
  }'

# --- 2. Alte Instanzen stoppen ----------------------------------------------
step "Stoppe laufende MailStrip-Prozesse"
# bootout = Dienst entladen. Fehler ignorieren, falls noch nicht installiert.
launchctl bootout "$GUI/$LABEL_STRIP" 2>/dev/null || true
launchctl bootout "$GUI/$LABEL_CHECK" 2>/dev/null || true
# Auch Prozesse beenden, die nicht über launchd laufen.
pkill -x MailStrip 2>/dev/null || true                    # z. B. manuell gestarteter Test
pkill -f MailStrip-Checker.ps1 2>/dev/null || true

# --- 3. Dateien kopieren -----------------------------------------------------
step "Kopiere Dateien nach $APP_DIR"
# Ordner anlegen (-p: kein Fehler, wenn schon vorhanden).
mkdir -p "$APP_DIR" "$LOG_DIR" "$AGENT_DIR"
# PowerShell-Skripte immer überschreiben -> Updates aus GitHub kommen an.
cp "$REPO_DIR"/scripts/*.ps1 "$APP_DIR/"
# Alte Statusdatei der Vorversion entfernen (sonst evtl. Fehlalarm).
rm -f "$APP_DIR/state.txt"
# Config nur beim ersten Mal kopieren – eigene Änderungen bleiben erhalten.
if [ ! -f "$APP_DIR/config.json" ]; then
  cp "$REPO_DIR/config/config.json" "$APP_DIR/config.json"
  echo "config.json angelegt"
else
  echo "config.json existiert – bleibt unverändert"
  # Neue Einstellungen aus der Vorlage ergänzen, ohne eigene Werte zu ändern.
  # Pfade per Umgebungsvariable übergeben (pwsh -Command kennt kein $args).
  CFG_USER="$APP_DIR/config.json" CFG_TMPL="$REPO_DIR/config/config.json" \
  "$PWSH" -NoLogo -NoProfile -Command '
    $user = Get-Content $env:CFG_USER -Raw | ConvertFrom-Json
    $tmpl = Get-Content $env:CFG_TMPL -Raw | ConvertFrom-Json
    # Jede Einstellung der Vorlage, die in deiner Datei fehlt, wird ergänzt.
    $added = foreach ($p in $tmpl.PSObject.Properties) {
      if (-not $user.PSObject.Properties[$p.Name]) {
        $user | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value; $p.Name }
    }
    if ($added) { $user | ConvertTo-Json -Depth 5 | Set-Content $env:CFG_USER -Encoding utf8
                  Write-Host "Ergänzt: $($added -join ", ")" }
  '
fi

# Login.command: Menüeintrag öffnet damit ein Terminal zur Anmeldung.
# Der pwsh-Pfad wird beim Installieren fest eingetragen.
cat > "$APP_DIR/Login.command" <<CMD
#!/bin/bash
"$PWSH" -NoLogo -NoProfile -File "$APP_DIR/Login.ps1"
read -r -p "Enter drücken zum Schließen"
CMD
# Ausführbar machen, sonst öffnet macOS die Datei nur im Editor.
chmod +x "$APP_DIR/Login.command"

# --- 4. Swift-App bauen ------------------------------------------------------
step "Baue Balken-App"
# -O = optimiert bauen. Ergebnis ist eine einzelne ausführbare Datei.
swiftc -O "$REPO_DIR/src/MailStrip.swift" -o "$APP_DIR/MailStrip"
# Quarantäne-Flag entfernen (falls das Repo als ZIP heruntergeladen wurde).
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

# --- 5. Anmelden -------------------------------------------------------------
step "Anmeldung bei Microsoft Graph"
# Öffnet den Device-Code-Dialog. Token wird im Benutzer-Cache gespeichert.
"$PWSH" -NoLogo -NoProfile -File "$APP_DIR/Login.ps1"

# --- 6. LaunchAgents ---------------------------------------------------------
step "Richte Autostart ein"

# Plist = Konfigurationsdatei für launchd (Apples Dienst-Manager).
# Balken: startet beim Login. KeepAlive nur bei Absturz – "MailStrip beenden"
# im Menü (normales Ende) wird respektiert bis zum nächsten Login.
cat > "$AGENT_DIR/$LABEL_STRIP.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL_STRIP</string>
  <key>ProgramArguments</key><array><string>$APP_DIR/MailStrip</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardErrorPath</key><string>$LOG_DIR/strip.log</string>
</dict></plist>
PLIST

# Checker: läuft dauerhaft, wird bei jedem Ende nach 30 s neu gestartet.
# ThrottleInterval verhindert schnelle Neustart-Schleifen bei Fehlern.
# PATH wird gesetzt, damit 'id' und 'launchctl' im Skript gefunden werden.
cat > "$AGENT_DIR/$LABEL_CHECK.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL_CHECK</string>
  <key>ProgramArguments</key><array>
    <string>$PWSH</string><string>-NoLogo</string><string>-NoProfile</string>
    <string>-File</string><string>$APP_DIR/MailStrip-Checker.ps1</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/checker.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/checker.log</string>
</dict></plist>
PLIST

# bootstrap = Dienst laden UND sofort starten (RunAtLoad).
# Ab jetzt startet launchd beide Dienste bei jedem Login automatisch.
launchctl bootstrap "$GUI" "$AGENT_DIR/$LABEL_STRIP.plist"
launchctl bootstrap "$GUI" "$AGENT_DIR/$LABEL_CHECK.plist"

# Zusammenfassung mit den wichtigsten Pfaden.
step "Fertig"
echo "Balken und Mail-Prüfung laufen und starten nach jedem Neustart automatisch."
echo "Log:    $LOG_DIR/checker.log"
echo "Config: $APP_DIR/config.json"
