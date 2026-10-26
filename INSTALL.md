# MailStrip – Installationsanleitung

Diese Anleitung führt Schritt für Schritt durch die Installation auf einem Mac. **Admin-Rechte sind nicht nötig**, sofern die Firma die Xcode Command Line Tools nicht sperrt.

Dauer: ca. 5–10 Minuten (länger, falls die Command Line Tools erst installiert werden müssen).

---

## 1. Voraussetzungen

Der Installer prüft alles selbst und installiert Fehlendes automatisch. Zur Übersicht:

| Voraussetzung | Wofür | Automatisch? |
|---|---|---|
| macOS (Apple Silicon oder Intel) | Betriebssystem | – |
| Xcode Command Line Tools | `swiftc` zum Bauen der Balken-App | Ja: Apple-Dialog wird geöffnet, du klickst „Installieren“ |
| PowerShell 7 (`pwsh`) | Mail-Prüfung | Ja: wird ohne Admin nach `~/.local` heruntergeladen |
| Module `Microsoft.Graph.Authentication`, `.Users`, `.Mail` | Zugriff auf Mails und Verzeichnis | Ja: für den aktuellen Benutzer |
| Internet zu `github.com`, `powershellgallery.com`, `login.microsoftonline.com` | Downloads und Anmeldung | wird geprüft |
| Microsoft-365-Konto mit Rechten `Mail.Read` und `User.Read.All` | Anmeldung | Anmeldung im Browser |
| `git` (optional) | nur zum Herunterladen per `git clone` | – |

Kann etwas nicht automatisch installiert werden, zeigt der Installer einen **Hilfetext** mit den nächsten Schritten und bricht ab. Nach dem Beheben einfach `./install.sh` erneut ausführen.

## 2. Quellen herunterladen

**Variante A – mit git:**

```bash
mkdir -p ~/Documents/Sources
cd ~/Documents/Sources
git clone https://github.com/ABrolund/mailstrip.git
cd mailstrip
```

Das Repo ist privat: Bei der Abfrage den GitHub-Benutzernamen und als Passwort einen **Personal Access Token** eingeben.

**Variante B – als ZIP:**

```bash
mkdir -p ~/Documents/Sources
unzip ~/Downloads/mailstrip-v4.zip -d ~/Documents/Sources/
cd ~/Documents/Sources/mailstrip
```

## 3. Installer starten

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

Der Installer zeigt jeden Schritt mit `==>` an und meldet Erfolg mit `✓`, Warnungen mit `!`.

### Was während der Installation passiert

1. **System und Internet prüfen.** Nicht erreichbare Dienste werden nur gemeldet.
2. **Command Line Tools.** Fehlen sie, öffnet sich ein Apple-Fenster: auf **Installieren** klicken. Der Installer wartet bis zu 30 Minuten.
3. **PowerShell.** Fehlt sie, wird die aktuelle Version von GitHub geladen und unter `~/.local/share/powershell` abgelegt. `~/.local/bin` wird in `~/.zshrc` zum PATH hinzugefügt.
4. **Graph-Module** werden installiert, falls nötig.
5. **Dateien kopieren** nach `~/Library/Application Support/MailStrip`. Eine vorhandene `config.json` bleibt erhalten, neue Einstellungen werden ergänzt.
6. **App bauen.**
7. **Anmeldung:** Im Terminal erscheint ein Code und ein Link (`https://microsoft.com/devicelogin`). Link öffnen, Code eingeben, mit dem Firmenkonto anmelden, bis „Authentication complete“ erscheint.
8. **Autostart** einrichten. Ab jetzt starten Balken und Mail-Prüfung nach jedem Neustart automatisch.

## 4. Prüfen, ob alles läuft

```bash
launchctl list | grep mailstrip
```

Es sollten zwei Zeilen erscheinen (`com.andreasbrolund.mailstrip` und `…checker`). In der Menüleiste steht `○` (kein Alarm) oder farbige Punkte.

**Funktionstest:**

1. Eigene Adresse vorübergehend in `extraManagementAddresses` eintragen:
   ```bash
   open -e ~/Library/Application\ Support/MailStrip/config.json
   ```
2. Sich selbst eine Mail schicken → innerhalb von ca. 60 s erscheint ein **roter** Balken.
3. Mail als gelesen markieren → Balken verschwindet innerhalb von ca. 60 s.
4. Eigene Adresse wieder entfernen.

## 5. Einrichten

Die wichtigsten Einstellungen in `config.json` (wirken ohne Neustart):

| Einstellung | Beispiel |
|---|---|
| `customerDomains` | `["philips.com", "volkswagen.de"]` |
| `workDays` | `["Monday","Tuesday","Wednesday","Thursday"]` |
| `lookbackHours` | `24` |
| `ignoreFolders` | `["Newsletter", "Inbox/Jira"]` – Ordnername oder Pfad; Unterordner werden mit ignoriert |

Die vollständige Liste steht in der [README](README.md#konfiguration).

## 6. Update

```bash
cd ~/Documents/Sources/mailstrip
git pull
./install.sh
```

## 7. Deinstallation

```bash
cd ~/Documents/Sources/mailstrip
./uninstall.sh
```

Optional: heruntergeladenes PowerShell entfernen mit `rm -rf ~/.local/share/powershell ~/.local/bin/pwsh`.

## 8. Häufige Probleme

| Meldung / Symptom | Lösung |
|---|---|
| Xcode-Dialog erscheint nicht oder verlangt Admin-Passwort | Installation gesperrt → Self Service oder IT um „Xcode Command Line Tools“ bitten |
| `PowerShell konnte nicht installiert werden` | GitHub wird blockiert (Proxy/Zscaler) → PowerShell-.pkg manuell installieren oder IT fragen |
| `Graph-Module konnten nicht installiert werden` | PowerShell Gallery blockiert → IT um Freigabe von `www.powershellgallery.com` bitten |
| `Admin approval required` bei der Anmeldung | Rechte `Mail.Read` / `User.Read.All` müssen von der IT freigegeben werden |
| `⚠︎ Anmeldung nötig` in der Menüleiste | Menü → **Anmelden bei Microsoft …** |
| `⚠︎ Letzte Prüfung …` | Checker läuft nicht → `tail -50 ~/Library/Logs/MailStrip/checker.log` |
| Terminal fragt nach Zugriff auf „Dokumente“ | **Erlauben** klicken |
