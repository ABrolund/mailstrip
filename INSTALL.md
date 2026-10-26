# MailStrip – Installationsanleitung

Schritt-für-Schritt-Installation auf einem Mac. **Admin-Rechte sind nicht nötig**, sofern die Firma die Xcode Command Line Tools nicht sperrt.

Dauer: ca. 5–10 Minuten (länger, falls die Command Line Tools erst installiert werden müssen).

---

## 1. Voraussetzungen

Der Installer prüft alles selbst und installiert Fehlendes automatisch.

| Voraussetzung | Wofür | Automatisch? |
|---|---|---|
| macOS (Apple Silicon oder Intel) | Betriebssystem | – |
| Xcode Command Line Tools | `swiftc` zum Bauen der Balken-App | Ja: Apple-Dialog, du klickst „Installieren“ |
| PowerShell 7 (`pwsh`) | Mail-Prüfung | Ja: Download ohne Admin nach `~/.local` |
| Module `Microsoft.Graph.Authentication`, `.Users`, `.Mail` | Zugriff auf Mails und Verzeichnis | Ja: für den aktuellen Benutzer |
| Internet zu `github.com`, `powershellgallery.com`, `login.microsoftonline.com` | Downloads und Anmeldung | wird geprüft |
| Microsoft-365-Konto mit `Mail.Read` und `User.Read.All` | Anmeldung | Anmeldung im Browser |
| `git` (optional) | nur für `git clone` | – |

Kann etwas nicht automatisch installiert werden, zeigt der Installer einen **Hilfetext** mit den nächsten Schritten. Danach `./install.sh` erneut ausführen.

## 2. Quellen herunterladen

**Variante A – mit git:**

```bash
mkdir -p ~/Documents/Sources
cd ~/Documents/Sources
git clone https://github.com/ABrolund/mailstrip.git
cd mailstrip
```

Das Repo ist privat: als Passwort einen **Personal Access Token** eingeben.

**Variante B – als ZIP:**

```bash
mkdir -p ~/Documents/Sources
unzip -o ~/Downloads/mailstrip-v7.zip -d ~/Documents/Sources/
cd ~/Documents/Sources/mailstrip
```

## 3. Installer starten

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

Jeder Schritt erscheint mit `==>`, Erfolg mit `✓`, Warnungen mit `!`.

### Ablauf

1. **System und Internet prüfen.**
2. **Command Line Tools:** fehlen sie, öffnet sich ein Apple-Fenster → **Installieren**.
3. **PowerShell:** fehlt sie, wird sie von GitHub geladen; `~/.local/bin` kommt in `~/.zshrc`.
4. **Graph-Module** werden bei Bedarf installiert.
5. **Dateien kopieren** nach `~/Library/Application Support/MailStrip`. Eine vorhandene `config.json` bleibt erhalten, neue Einstellungen werden ergänzt.
6. **App bauen.**
7. **Anmeldung – nur wenn nötig.** Ist noch ein gültiges Token gespeichert, erscheint `✓ bereits angemeldet`. Sonst: Code und Link (`https://microsoft.com/devicelogin`) erscheinen → Link öffnen, Code eingeben, mit dem Firmenkonto anmelden. Die Prüfung dauert bis zu 30 s.
8. **Autostart** einrichten.

## 4. Prüfen, ob alles läuft

```bash
launchctl list | grep mailstrip
```

Zwei Zeilen sollten erscheinen. In der Menüleiste steht `○` oder farbige Punkte.

**Funktionstest:**

1. Eigene Adresse vorübergehend in `extraManagementAddresses` eintragen:
   ```bash
   open -e ~/Library/Application\ Support/MailStrip/config.json
   ```
2. Sich selbst eine Mail schicken → nach ca. 60 s **roter** Balken.
3. Mail als gelesen markieren → Balken verschwindet nach ca. 60 s.
4. Eigene Adresse wieder entfernen.

**@-Erwähnung testen:** Eine Kollegin/einen Kollegen bitten, dir eine Mail mit `@Andreas Brolund` zu schicken → **türkiser** Balken.

## 5. Einrichten

| Einstellung | Beispiel |
|---|---|
| `customerDomains` | `["philips.com", "volkswagen.de"]` |
| `workDays` | `["Monday","Tuesday","Wednesday","Thursday"]` |
| `lookbackHours` | `24` |
| `ignoreFolders` | `["Newsletter", "Inbox/Jira"]` |
| `mentionsEnabled` / `mentionNames` | `true` / `["Andreas Brolund", "Andreas"]` |

Vollständige Liste: [README](README.md#konfiguration).

## 6. Update

```bash
cd ~/Documents/Sources/mailstrip
git pull
./install.sh
```

## 7. Deinstallation

```bash
./uninstall.sh
```

Optional heruntergeladenes PowerShell entfernen: `rm -rf ~/.local/share/powershell ~/.local/bin/pwsh`

## 8. Häufige Probleme

| Meldung / Symptom | Lösung |
|---|---|
| Xcode-Dialog erscheint nicht oder verlangt Admin-Passwort | Self Service oder IT um „Xcode Command Line Tools“ bitten |
| `PowerShell konnte nicht installiert werden` | GitHub blockiert → PowerShell-.pkg manuell oder über IT |
| `Graph-Module konnten nicht installiert werden` | IT um Freigabe von `www.powershellgallery.com` bitten |
| `Admin approval required` bei der Anmeldung | Rechte müssen von der IT freigegeben werden |
| Installer fragt trotz gültiger Anmeldung erneut | Token im Cache nicht wiederverwendbar → einfach erneut anmelden |
| `You must install .NET to run this application` | Es wurde eine PowerShell ohne .NET-Pfad eingetragen → `./install.sh` erneut ausführen (ab v7 wird jede PowerShell wie im Hintergrund getestet) |
| `⚠︎ Anmeldung nötig` in der Menüleiste | Menü → **Anmelden bei Microsoft …** |
| `⚠︎ Letzte Prüfung …` | `tail -50 ~/Library/Logs/MailStrip/checker.log` |
| Terminal fragt nach Zugriff auf „Dokumente“ | **Erlauben** klicken |
