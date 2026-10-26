#!/bin/bash
# =============================================================================
# install.sh – richtet MailStrip komplett ein (ohne Admin-Rechte)
# -----------------------------------------------------------------------------
# Ablauf:
#   0. System prüfen (macOS, Prozessor)
#   1. Internetverbindung zu den benötigten Diensten prüfen
#   2. Xcode Command Line Tools (swiftc)  -> fehlt: Installationsdialog starten
#   3. PowerShell (pwsh)                  -> fehlt: ohne Admin nach ~/.local laden
#   4. Microsoft-Graph-Module             -> fehlen: für den Benutzer installieren
#   5. alte Instanzen stoppen
#   6. Dateien nach ~/Library/Application Support/MailStrip kopieren
#   7. Swift-App bauen
#   8. Anmeldung – nur wenn kein gültiges Token im Cache liegt
#   9. zwei LaunchAgents anlegen -> Start automatisch nach jedem Login/Reboot
# Kann etwas nicht automatisch erledigt werden, erscheint ein Hilfetext mit
# den nächsten Schritten und das Skript bricht ab.
# Erneut ausführen ist gefahrlos (z. B. nach einem Update aus GitHub).
# =============================================================================
# Hinweis: -e bricht bei Fehlern ab, -u bei unbekannten Variablen,
# pipefail meldet Fehler auch mitten in einer Pipe (a | b).
# Befehle mit '|| …' werden bewusst abgefangen und brechen NICHT ab.
set -euo pipefail

# --- Pfade und Namen ---------------------------------------------------------
# REPO_DIR: von hier werden Quellen gelesen (dein Git-Checkout).
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Library/Application Support/MailStrip"     # Programm + Daten
LOG_DIR="$HOME/Library/Logs/MailStrip"                    # Logs (Konsole-App)
AGENT_DIR="$HOME/Library/LaunchAgents"                    # Autostart pro Benutzer
LOCAL_BIN="$HOME/.local/bin"                              # eigene Programme ohne Admin
PS_HOME="$HOME/.local/share/powershell"                   # Ablage für heruntergeladenes pwsh
GUI="gui/$(id -u)"                                        # launchd-Domäne des Benutzers
LABEL_STRIP="com.andreasbrolund.mailstrip"                # Balken (Swift)
LABEL_CHECK="com.andreasbrolund.mailstrip.checker"        # Mail-Prüfung (PowerShell)
# Ersatzversion, falls die GitHub-API nicht erreichbar ist (LTS-Version).
# (Die aktuelle Version wird normalerweise automatisch ermittelt.)
PS_FALLBACK_VERSION="7.4.6"

# --- Hilfsfunktionen ---------------------------------------------------------
# Überschrift pro Schritt.
step() { echo; echo "==> $*"; }
# Kurze Statusmeldungen.
ok()   { echo "    ✓ $*"; }
warn() { echo "    ! $*"; }

# Hilfetext anzeigen und abbrechen.
#   $1 = Überschrift, $2 = Text mit den nächsten Schritten.
# Alle Hilfetexte laufen hier zusammen -> einheitliches Aussehen.
die_help() {
  echo
  echo "------------------------------------------------------------------"
  echo " ✗ $1"
  echo "------------------------------------------------------------------"
  echo "$2"
  echo
  echo "Danach ./install.sh erneut ausführen. Details: INSTALL.md"
  exit 1
}

# Prüft, ob eine URL erreichbar ist (HTTP-Antwort innerhalb von 10 s).
# -o /dev/null: Inhalt verwerfen, nur Erreichbarkeit zählt.
# Ein HTTP-Fehler (z. B. 403) gilt trotzdem als erreichbar.
reachable() { curl -sS -o /dev/null --max-time 10 "$1" 2>/dev/null; }

# --- 0. System ---------------------------------------------------------------
step "Prüfe System"
# MailStrip nutzt macOS-Fenster und launchd -> läuft nur auf macOS.
[ "$(uname -s)" = "Darwin" ] || die_help "Kein macOS" "MailStrip läuft nur auf macOS."
# Prozessor bestimmt, welches PowerShell-Paket geladen wird.
ARCH="$(uname -m)"                                        # arm64 (Apple Silicon) oder x86_64
ok "macOS $(sw_vers -productVersion), Prozessor $ARCH"

# --- 1. Netzwerk -------------------------------------------------------------
# Nur Warnungen: Wird ein Dienst nicht gebraucht (z. B. pwsh schon da),
# ist eine Sperre egal. Bei Bedarf greift später der passende Hilfetext.
step "Prüfe Internetverbindung"
# Ergebnisse merken (1 = erreichbar), werden später für Hinweise genutzt.
NET_GITHUB=1; NET_MS=1
reachable "https://github.com"                 && ok "github.com"            || { NET_GITHUB=0; warn "github.com nicht erreichbar"; }
reachable "https://www.powershellgallery.com"  && ok "powershellgallery.com" || warn "powershellgallery.com nicht erreichbar"
reachable "https://login.microsoftonline.com"  && ok "Microsoft-Anmeldung"   || { NET_MS=0;     warn "login.microsoftonline.com nicht erreichbar"; }

# --- 2. Xcode Command Line Tools ---------------------------------------------
# Liefern swiftc. /usr/bin/swiftc existiert immer als Platzhalter, daher
# zusätzlich prüfen, ob "swiftc --version" wirklich funktioniert.
step "Prüfe Xcode Command Line Tools (swiftc)"
# Kleine Prüffunktion, wird vor und nach der Installation genutzt.
clt_ok() { xcode-select -p >/dev/null 2>&1 && swiftc --version >/dev/null 2>&1; }
# Fall A: schon installiert. Fall B: Dialog starten und warten.
if clt_ok; then
  ok "vorhanden: $(xcode-select -p)"
else
  warn "fehlen – starte Apple-Installationsdialog"
  # Öffnet ein Fenster "Installieren". Je nach Firmenrichtlinie ist das ohne
  # Admin erlaubt oder gesperrt.
  xcode-select --install >/dev/null 2>&1 || true
  echo "    Bitte im Dialog auf 'Installieren' klicken. Warte bis zu 30 Minuten …"
  # Alle 10 s nachsehen, ob die Installation fertig ist (max. 180 × 10 s).
  for _ in $(seq 1 180); do clt_ok && break; sleep 10; done
  clt_ok || die_help "Xcode Command Line Tools konnten nicht installiert werden" \
"Möglichkeiten:
  1. Im Terminal 'xcode-select --install' ausführen und im Dialog
     auf 'Installieren' klicken. Erscheint kein Dialog oder wird ein
     Admin-Passwort verlangt, ist die Installation gesperrt.
  2. Self Service / Firmen-App-Katalog nach 'Command Line Tools' durchsuchen.
  3. IT bitten, die 'Xcode Command Line Tools' zu installieren.
  4. Mit Apple-ID: https://developer.apple.com/download/all/
     -> 'Command Line Tools for Xcode' herunterladen (.dmg, braucht Admin)."
  ok "installiert"
fi

# --- 3. PowerShell -----------------------------------------------------------
step "Prüfe PowerShell (pwsh)"
# Bekannte Orte durchsuchen; erster Treffer gewinnt.
# Gibt den Pfad auf stdout aus, Exit-Code 0 = gefunden.
# Reihenfolge: feste Symlinks zuerst (/opt/homebrew/bin/pwsh zeigt auf
# Homebrews Start-Skript, das DOTNET_ROOT setzt). Pfade in .../libexec/
# sind das nackte Programm OHNE dieses Skript -> werden übersprungen.
# Jeder Kandidat wird in einer LEEREN Umgebung (env -i) gestartet – genau
# so, wie launchd und Login.command ihn später aufrufen. Was nur im
# Terminal funktioniert (z. B. wegen ~/.zshrc), fällt hier durch.
find_pwsh() {
  for p in /opt/homebrew/bin/pwsh /usr/local/bin/pwsh "$LOCAL_BIN/pwsh" "$(command -v pwsh 2>/dev/null || true)"; do
    [ -n "$p" ] && [ -x "$p" ] || continue
    case "$p" in */libexec/*) continue ;; esac
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$p" -NoLogo -NoProfile -Command 'exit 0' >/dev/null 2>&1 \
      && { echo "$p"; return 0; }
    warn "$p startet ohne Terminal-Umgebung nicht – übersprungen" >&2
  done
  return 1
}

# Lädt das offizielle PowerShell-Archiv von GitHub und entpackt es nach
# ~/.local/share/powershell/<Version>. Kein Installer, kein Admin nötig.
install_pwsh() {
  # Prozessorname von macOS auf PowerShell-Namen abbilden.
  local arch="arm64"; [ "$ARCH" = "x86_64" ] && arch="x64"
  # Neueste Version über die GitHub-API ermitteln ("tag_name": "v7.x.y").
  # '|| true' verhindert den Abbruch durch set -e, wenn GitHub nicht antwortet.
  local ver
  ver="$(curl -fsSL --max-time 20 https://api.github.com/repos/PowerShell/PowerShell/releases/latest 2>/dev/null \
         | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/' || true)"
  [ -n "$ver" ] || { warn "Version nicht ermittelbar – nutze $PS_FALLBACK_VERSION"; ver="$PS_FALLBACK_VERSION"; }
  # Offizieller Download-Link (gleiches Muster für jede Version).
  local url="https://github.com/PowerShell/PowerShell/releases/download/v$ver/powershell-$ver-osx-$arch.tar.gz"
  local dest="$PS_HOME/$ver"
  echo "    Lade PowerShell $ver ($arch) …"
  mkdir -p "$dest" "$LOCAL_BIN"
  # -f: bei HTTP-Fehler abbrechen, -L: Weiterleitungen folgen.
  curl -fL --max-time 600 --progress-bar -o "$dest/pwsh.tar.gz" "$url" || return 1
  # Archiv entpacken; enthält pwsh und alle Bibliotheken.
  tar -xzf "$dest/pwsh.tar.gz" -C "$dest" || return 1
  # Archiv wird nicht mehr gebraucht.
  rm -f "$dest/pwsh.tar.gz"
  # Ausführbar machen (geht beim Entpacken teils verloren).
  chmod +x "$dest/pwsh"
  # Quarantäne entfernen, sonst blockiert Gatekeeper den ersten Start.
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  # Fester Pfad ~/.local/bin/pwsh zeigt auf die aktuelle Version.
  ln -sf "$dest/pwsh" "$LOCAL_BIN/pwsh"
}

# Ab hier steht der Pfad in $PWSH und wird überall absolut verwendet.
if PWSH="$(find_pwsh)"; then
  ok "vorhanden: $PWSH ($("$PWSH" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))"
else
  warn "fehlt – lade PowerShell ohne Admin-Rechte herunter"
  [ "$NET_GITHUB" = 1 ] || warn "github.com war nicht erreichbar – Versuch trotzdem"
  if install_pwsh && PWSH="$(find_pwsh)"; then
    ok "installiert: $PWSH"
    # ~/.local/bin für künftige Terminals in den PATH aufnehmen (einmalig).
    # Nur für eigene Terminal-Nutzung; MailStrip selbst nutzt den absoluten Pfad.
    if ! grep -qs '.local/bin' "$HOME/.zshrc"; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
      ok "PATH in ~/.zshrc ergänzt (gilt ab dem nächsten Terminal)"
    fi
  else
    die_help "PowerShell konnte nicht installiert werden" \
"Mögliche Ursachen: Proxy/Zscaler blockiert GitHub, oder Gatekeeper sperrt
das Programm.
Möglichkeiten:
  1. Im Browser öffnen: https://github.com/PowerShell/PowerShell/releases
     -> 'powershell-<Version>-osx-arm64.pkg' installieren (braucht ggf. Admin).
  2. Self Service / Firmen-App-Katalog nach 'PowerShell' durchsuchen.
  3. Mit Homebrew (falls vorhanden): brew install --cask powershell
  4. IT bitten, PowerShell 7 zu installieren."
  fi
fi

# --- 4. Microsoft-Graph-Module -----------------------------------------------
# Nur die drei benötigten Teilmodule; fehlende werden für den Benutzer
# installiert. -Force unterdrückt die Rückfrage "Untrusted repository".
# Exit-Code 1, wenn danach noch ein Modul fehlt.
step "Prüfe Microsoft-Graph-Module"
# Der folgende PowerShell-Block läuft in einem eigenen Prozess.
# $ErrorActionPreference Stop -> jeder Fehler landet im catch-Zweig.
if ! "$PWSH" -NoLogo -NoProfile -Command '
  $ErrorActionPreference = "Stop"
  $missing = @()
  foreach ($m in "Microsoft.Graph.Authentication","Microsoft.Graph.Users","Microsoft.Graph.Mail") {
    if (Get-Module -ListAvailable -Name $m) { Write-Host "    ✓ $m"; continue }
    Write-Host "    … installiere $m"
    try   { Install-Module $m -Scope CurrentUser -Force -AllowClobber -Repository PSGallery }
    catch { Write-Host "    ! $($_.Exception.Message)"; $missing += $m }
  }
  # Zur Sicherheit einmal laden – erkennt beschädigte Installationen.
  try { Import-Module Microsoft.Graph.Authentication } catch { $missing += "Microsoft.Graph.Authentication (Laden)" }
  if ($missing) { exit 1 }'; then
  die_help "Microsoft-Graph-Module konnten nicht installiert werden" \
"Mögliche Ursache: Die PowerShell Gallery ist gesperrt (Proxy/Zscaler).
Möglichkeiten:
  1. Manuell in pwsh versuchen und Fehlermeldung prüfen:
       pwsh
       Install-Module Microsoft.Graph.Authentication,Microsoft.Graph.Users,Microsoft.Graph.Mail -Scope CurrentUser
  2. Zscaler kurz deaktivieren (falls erlaubt) und erneut versuchen.
  3. IT bitten, www.powershellgallery.com freizugeben."
fi

# --- 5. Alte Instanzen stoppen -----------------------------------------------
step "Stoppe laufende MailStrip-Prozesse"
# Wichtig vor dem Kopieren: laufende Programme halten Dateien offen.
# bootout = Dienst entladen. Fehler ignorieren, falls noch nicht installiert.
launchctl bootout "$GUI/$LABEL_STRIP" 2>/dev/null || true
launchctl bootout "$GUI/$LABEL_CHECK" 2>/dev/null || true
# Auch Prozesse beenden, die nicht über launchd laufen (z. B. manueller Test).
pkill -x MailStrip 2>/dev/null || true
pkill -f MailStrip-Checker.ps1 2>/dev/null || true
ok "erledigt"

# --- 6. Dateien kopieren -----------------------------------------------------
step "Kopiere Dateien nach $APP_DIR"
# Ordner anlegen (-p: kein Fehler, wenn schon vorhanden).
mkdir -p "$APP_DIR" "$LOG_DIR" "$AGENT_DIR"
# PowerShell-Skripte immer überschreiben -> Updates aus GitHub kommen an.
cp "$REPO_DIR"/scripts/*.ps1 "$APP_DIR/"
# Alte Statusdatei der ersten Version entfernen (sonst evtl. Fehlalarm).
# (state.json wird vom Checker beim ersten Durchlauf neu geschrieben.)
rm -f "$APP_DIR/state.txt"
# Config nur beim ersten Mal kopieren – eigene Änderungen bleiben erhalten.
if [ ! -f "$APP_DIR/config.json" ]; then
  cp "$REPO_DIR/config/config.json" "$APP_DIR/config.json"
  ok "config.json angelegt"
else
  ok "config.json existiert – eigene Werte bleiben erhalten"
  # Neue Einstellungen aus der Vorlage ergänzen, veraltete entfernen.
  # Pfade per Umgebungsvariable übergeben (pwsh -Command kennt kein $args).
  CFG_USER="$APP_DIR/config.json" CFG_TMPL="$REPO_DIR/config/config.json" \
  "$PWSH" -NoLogo -NoProfile -Command '
    $user = Get-Content $env:CFG_USER -Raw | ConvertFrom-Json
    $tmpl = Get-Content $env:CFG_TMPL -Raw | ConvertFrom-Json
    # Jede Einstellung der Vorlage, die in deiner Datei fehlt, wird ergänzt.
    $added = @(foreach ($p in $tmpl.PSObject.Properties) {
      if (-not $user.PSObject.Properties[$p.Name]) {
        $user | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value; $p.Name }
    })
    # Veraltete Einstellung der Vorversion entfernen.
    if ($user.PSObject.Properties["maxAgeDays"]) { $user.PSObject.Properties.Remove("maxAgeDays"); $added += "(maxAgeDays entfernt)" }
    if ($added) { $user | ConvertTo-Json -Depth 5 | Set-Content $env:CFG_USER -Encoding utf8
                  Write-Host ("    ✓ ergänzt: " + ($added -join ", ")) }
  '
fi

# Login.command: Menüeintrag öffnet damit ein Terminal zur Anmeldung.
# Variablen in diesem Heredoc werden JETZT eingesetzt (kein 'CMD' in Anführungszeichen).
cat > "$APP_DIR/Login.command" <<CMD
#!/bin/bash
"$PWSH" -NoLogo -NoProfile -File "$APP_DIR/Login.ps1"
read -r -p "Enter drücken zum Schließen"
CMD
# Ausführbar machen, sonst öffnet macOS die Datei nur im Editor.
chmod +x "$APP_DIR/Login.command"

# --- 7. Swift-App bauen ------------------------------------------------------
step "Baue Balken-App"
# -O = optimiert bauen. Ergebnis ist eine einzelne ausführbare Datei.
# Bei Fehlern zeigt swiftc Datei, Zeile und Ursache direkt an.
swiftc -O "$REPO_DIR/src/MailStrip.swift" -o "$APP_DIR/MailStrip" || die_help "Bauen der App fehlgeschlagen" \
"Die Fehlermeldung des Compilers steht direkt oberhalb.
  - Bitte die komplette Ausgabe kopieren und melden.
  - Nach einem macOS-Update hilft oft: xcode-select --install"
# Quarantäne-Flag entfernen (falls das Repo als ZIP heruntergeladen wurde).
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
ok "gebaut: $APP_DIR/MailStrip"

# --- 8. Anmelden (nur wenn nötig) --------------------------------------------
step "Anmeldung bei Microsoft Graph"
[ "$NET_MS" = 1 ] || warn "Microsoft-Anmeldung war nicht erreichbar – Versuch trotzdem"

# Prüft, ob im Benutzer-Cache noch ein gültiges Token mit beiden Rechten liegt.
# Läuft als Hintergrund-Job mit 30 s Zeitlimit: Ist KEIN Token vorhanden,
# würde Connect-MgGraph sonst auf eine Device-Code-Eingabe warten und hängen.
# Exit-Code 0 = gültig, 1 = Anmeldung nötig.
token_ok() {
  "$PWSH" -NoLogo -NoProfile -Command '
    $job = Start-Job {
      Connect-MgGraph -Scopes Mail.Read,User.Read.All -ContextScope CurrentUser `
                      -UseDeviceAuthentication -NoWelcome -ErrorAction Stop *> $null
      $c = Get-MgContext
      [bool]($c -and $c.Scopes -contains "Mail.Read" -and $c.Scopes -contains "User.Read.All")
    }
    # Wartet höchstens 30 s; danach gilt: nicht angemeldet.
    $done = Wait-Job $job -Timeout 30
    $ok   = $done -and ((Receive-Job $job -ErrorAction SilentlyContinue) -contains $true)
    Remove-Job $job -Force
    if ($ok) { exit 0 } else { exit 1 }' >/dev/null 2>&1
}

# Gültiges Token aus dem Cache? Dann keine neue Anmeldung nötig.
if token_ok; then
  ok "bereits angemeldet – überspringe Anmeldung"
else
  # Öffnet den Device-Code-Dialog. Token wird im Benutzer-Cache gespeichert.
  "$PWSH" -NoLogo -NoProfile -File "$APP_DIR/Login.ps1" || die_help "Anmeldung fehlgeschlagen" \
"Möglichkeiten:
  - 'Admin approval required' / 'Need admin approval': Die Berechtigungen
    Mail.Read und User.Read.All müssen von der IT freigegeben werden.
  - 'User canceled authentication': Im Browser den Code eingeben und
    die Anmeldung bis 'Authentication complete' abschließen.
  - Netzwerkfehler: Zscaler/VPN prüfen."
fi

# --- 9. LaunchAgents ---------------------------------------------------------
step "Richte Autostart ein"

# Plist = Konfigurationsdatei für launchd (Apples Dienst-Manager).
# Die Datei liegt in ~/Library/LaunchAgents -> gilt nur für diesen Benutzer.
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
    <key>PATH</key><string>$LOCAL_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
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
# Beide Dienste nacheinander laden; schlägt einer fehl, Hilfetext zeigen.
for L in "$LABEL_STRIP" "$LABEL_CHECK"; do
  launchctl bootstrap "$GUI" "$AGENT_DIR/$L.plist" || die_help "Autostart '$L' konnte nicht eingerichtet werden" \
"Möglichkeiten:
  - Einmal ab- und wieder anmelden (bzw. Mac neu starten), dann erneut installieren.
  - Prüfen, ob die Firma LaunchAgents sperrt:
      launchctl print $GUI/$L
  - Status ansehen: launchctl list | grep mailstrip"
done
ok "Autostart aktiv"

# Zusammenfassung mit den wichtigsten Pfaden.
# Ab hier läuft alles im Hintergrund, das Terminal kann geschlossen werden.
step "Fertig"
echo "Balken und Mail-Prüfung laufen und starten nach jedem Neustart automatisch."
echo "Log:    $LOG_DIR/checker.log"
echo "Config: $APP_DIR/config.json"
