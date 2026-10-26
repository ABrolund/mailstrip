# MailStrip

Ein langsam pulsierender Farbstreifen am oberen Bildschirmrand (macOS). Er erscheint **nur**, wenn relevante ungelesene Mails vorliegen.

| Farbe | Bedeutung |
|---|---|
| 🔴 Rot | Mail von höherem Management (Linie ab Ebene 2, Director, VP, C-Level …) |
| 🟡 Gelb | Mail vom direkten Line Manager |
| 🩵 Türkis | Du wirst in der Mail per **@** erwähnt |
| 🟢 Grün | Mail von einem Kunden |
| *kein Balken* | nichts davon ungelesen |

- **Vorrang**, falls mehreres zutrifft: Line Manager > Management > @-Erwähnung > Kunde.
- **Mehrere Kategorien gleichzeitig:** Die Farben wechseln nacheinander, ein Puls je Farbe.
- **Geschwindigkeit:** immer langsam (3 s pro Puls).
- **Zeitraum:** nur Mails der letzten 24 Arbeitsstunden; an freien Tagen wird nicht geprüft.
- **Ordner:** alle Ordner inkl. Unterordner – außer Gesendet, Gelöscht, Junk, Entwürfe, Postausgang und Ordnern aus `ignoreFolders`.
- **Ende des Alarms:** Mail lesen (spätestens nach 60 s weg) **oder** im Menü quittieren.

## Menüleiste

Das Symbol zeigt farbige Punkte je Kategorie und die Anzahl, z. B. `●● 3`. Ohne Alarm steht dort `○`, bei Problemen zusätzlich `⚠︎`.

- **Liste der auslösenden Mails**, gruppiert nach Kategorie: Betreff, Absender, Datum, Ordner (falls nicht Posteingang) und **Grund**.
- **Klick auf eine Mail:** öffnet sie in Outlook im Web.
- **⌥ Option gedrückt halten:** einzelne Mail quittieren.
- **Alarm löschen (alle quittieren)** / **Quittierte wieder anzeigen**.
- **Anmelden bei Microsoft …**, **Managerliste jetzt aktualisieren**, **Log öffnen**, **MailStrip beenden**.

---

## Architektur

```
┌──────────────────────────┐   schreibt    ┌────────────┐  liest alle 2 s  ┌────────────────────┐
│ MailStrip-Checker.ps1    │ ────────────▶ │ state.json │ ◀─────────────── │ MailStrip (Swift)  │
│ (PowerShell, alle 60 s)  │               └────────────┘                  │ Balken + Menü      │
│  • Microsoft Graph       │                                               │ dismissed.json     │
│  • management.json (1×/Woche)                                            └────────────────────┘
└──────────────────────────┘
        ▲ beide werden von launchd (LaunchAgents) beim Login gestartet
```

- **Swift-App** – nur Anzeige und Quittieren. Kein Zugriff auf Mails, keine Anmeldung.
- **PowerShell-Checker** – Anmeldung, Managerliste, Mail-Prüfung, Begründung je Treffer.
- **`state.json`** – Status (`ok`/`auth`), Zeitpunkt der Prüfung, Liste der Treffer.
- **`dismissed.json`** – IDs quittierter Mails; bereinigt sich selbst, sobald Mails gelesen sind.

## Projektstruktur

| Datei | Zweck |
|---|---|
| `src/MailStrip.swift` | Balken (ein Fenster pro Bildschirm), Animation, Menü, Quittieren |
| `scripts/MailStrip-Common.ps1` | Pfade, Logging, Status, Arbeitstage, Ordnerbaum, Anmeldung, Managerliste |
| `scripts/MailStrip-Checker.ps1` | Hintergrunddienst: prüft alle 60 s die Mails |
| `scripts/Login.ps1` | Interaktive Anmeldung + Aktualisierung der Managerliste |
| `config/config.json` | Vorlage der Einstellungen |
| `install.sh` | Prüft/installiert Voraussetzungen, komplette Einrichtung inkl. Autostart |
| `uninstall.sh` | Entfernt Autostart und optional alle Daten |
| `INSTALL.md` | Installationsanleitung |

## Installation / Update

Ausführliche Anleitung: **[INSTALL.md](INSTALL.md)**

```bash
cd ~/Documents/Sources/mailstrip
git pull            # bei Update
./install.sh
```

Bei einem Update mit gültigem Token wird die Anmeldung übersprungen.

## Konfiguration

Datei: `~/Library/Application Support/MailStrip/config.json`. Änderungen wirken beim nächsten Durchlauf, **kein Neustart nötig**.

| Schlüssel | Bedeutung |
|---|---|
| `customerDomains` | Domains, die als Kunde gelten (grün). Subdomains zählen mit. |
| `internalDomains` | Nur für diese Domains wird nach Management-Titeln gesucht. |
| `managementTitlePatterns` | Regex-Muster für Jobtitel, die rot werden (in JSON `\\b` statt `\b`). |
| `extraManagementAddresses` | Zusätzliche Adressen, die immer rot sind. |
| `intervalSeconds` | Prüfintervall (Standard 60). |
| `lookbackHours` | Nur ungelesene Mails der letzten N **Arbeitsstunden** (Standard 24). Montag 9:00 prüft ab Freitag 9:00. |
| `workDays` | Tage, an denen geprüft wird (englische Namen, Standard Mo–Fr). |
| `ignoreFolders` | Ordner, die nicht geprüft werden: Name (`"Newsletter"`) oder Pfad (`"Inbox/Jira"`); Unterordner mit. |
| `folderMapRefreshMinutes` | Wie oft der Ordnerbaum neu geladen wird (Standard 15). Neue Ordner werden sofort erkannt. |
| `mentionsEnabled` | @-Erwähnungen erkennen (türkis), Standard `true`. |
| `mentionNames` | Namen für die Ersatzerkennung, z. B. `["Andreas Brolund", "Andreas"]`. Leer = automatisch aus dem Verzeichnis. |
| `managerListRefreshDays` | Managerliste wird nach N Tagen neu geladen (Standard 7). |
| `managerChainMaxLevels` | Maximale Ebenen nach oben in deiner Linie. |

## Code-Erklärung

### Swift-App (`src/MailStrip.swift`)

- **`Category`**: `management`, `linemanager`, `mention`, `customer`. Die Reihenfolge bestimmt die Farbreihenfolge.
- **`MailItem` / `StatusFile`**: Abbild von `state.json`, gelesen mit `Codable`.
- **`StripWindow`**: randloses, transparentes Fenster ganz oben (`level = .screenSaver`, `ignoresMouseEvents`, auf allen Spaces), standardmäßig unsichtbar.
  - **Puls**: `CAKeyframeAnimation` auf `opacity`, dunkel → hell → dunkel in 3 s.
  - **Farbwechsel**: zweite Animation auf `backgroundColor` (`.discrete`), Dauer = Anzahl Farben × 3 s → Wechsel immer am dunkelsten Punkt.
- **`AppDelegate`**: liest `state.json` alle 2 s, blendet Fenster ein/aus, baut das Menü bei jedem Öffnen neu, verwaltet Quittierungen und erkennt Probleme (`⚠︎`).

### Gemeinsame Funktionen (`scripts/MailStrip-Common.ps1`)

- **`Write-StripStatus`**: schreibt `state.json` atomar.
- **`Test-WorkDay` / `Get-LookbackStart`**: Arbeitstag prüfen und Beginn des Zeitraums berechnen (freie Tage zählen nicht).
- **`Get-FolderMap`**: lädt den Ordnerbaum rekursiv und markiert ausgeschlossene Ordner (vererbt an Unterordner).
- **`Connect-MailStrip`**: Anmeldung mit `Mail.Read` und `User.Read.All`, Token im Benutzer-Cache.
- **`Update-ManagerList` / `Read-ManagerList`**: Managementkette + Titel-Treffer → Line Manager und Wörterbuch *Adresse → Grund*.

### Checker (`scripts/MailStrip-Checker.ps1`)

- **`Get-UnreadMessages`**: ein Aufruf über alle Ordner (`/me/messages`). Zuerst Beta-Schnittstelle mit `mentionsPreview`; geht das nicht, v1.0 mit `bodyPreview`.
- **`Test-Mentioned`**: `mentionsPreview.isMentioned` oder ersatzweise `@Name` in den ersten ca. 255 Zeichen.
- **`Get-InboxItems`**: verwirft Mails in ausgeschlossenen Ordnern und stuft den Rest mit Grund und Ordner ein.
- **Hauptschleife**: an freien Tagen pausieren, sonst anmelden → Managerliste → prüfen → `state.json` → 60 s warten.

### Autostart (`install.sh`)

| Label | Programm | Neustart |
|---|---|---|
| `com.andreasbrolund.mailstrip` | Swift-App | nur nach Absturz |
| `com.andreasbrolund.mailstrip.checker` | `pwsh MailStrip-Checker.ps1` | immer, frühestens nach 30 s |

## Fehlersuche

| Symptom | Ursache / Lösung |
|---|---|
| Alarm, aber unklar warum | Menü öffnen: Grund steht unter jeder Mail. Oder `checker.log`. |
| Falsche Person rot | Titel-Muster in `config.json` anpassen → **Managerliste jetzt aktualisieren** |
| Erwähnung nicht erkannt | Im Log nach „Ersatzerkennung“ suchen; ggf. `mentionNames` setzen |
| `⚠︎ Anmeldung nötig` | Menü **Anmelden bei Microsoft …** |
| `⚠︎ Letzte Prüfung …` | Checker läuft nicht: `launchctl list \| grep mailstrip`, Log prüfen |
| Rohdaten ansehen | `cat ~/Library/Application\ Support/MailStrip/state.json` |
| Log live | `tail -f ~/Library/Logs/MailStrip/checker.log` |

## Bekannte Grenzen

- Mails öffnen sich in **Outlook im Web**, nicht in der Outlook-App.
- Bei weitergeleiteten Mails zählt die weiterleitende Person als Absender.
- Ersatzerkennung für @-Erwähnungen sieht nur den Textanfang.
- Feiertage werden nicht erkannt.
- Wie lange das Token gültig bleibt, hängt von den Cerence-Richtlinien ab.

## Deinstallation

```bash
./uninstall.sh
```
