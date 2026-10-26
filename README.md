# MailStrip

Ein langsam pulsierender Farbstreifen am oberen Bildschirmrand (macOS). Er erscheint **nur**, wenn ungelesene Mails von Kunden oder Management im Outlook-Posteingang liegen.

| Farbe | Bedeutung |
|---|---|
| 🔴 Rot | Mail von höherem Management (Linie ab Ebene 2, Director, VP, C-Level …) |
| 🟡 Gelb | Mail vom direkten Line Manager |
| 🟢 Grün | Mail von einem Kunden |
| *kein Balken* | nichts davon ungelesen |

- **Mehrere Kategorien gleichzeitig:** Die Farben wechseln nacheinander, ein Puls je Farbe (z. B. rot → gelb → grün → rot …).
- **Geschwindigkeit:** immer langsam (3 s pro Puls).
- **Zeitraum:** nur Mails der letzten 24 Arbeitsstunden; am Wochenende wird nicht geprüft.
- **Ordner:** alle Ordner inkl. Unterordner – außer Gesendet, Gelöscht, Junk, Entwürfe, Postausgang und Ordnern aus `ignoreFolders`.
- **Ende des Alarms:** Mail lesen (spätestens nach 60 s weg) **oder** im Menü quittieren.

## Menüleiste

Das Symbol zeigt farbige Punkte je Kategorie und die Anzahl, z. B. `●● 3`. Ohne Alarm steht dort `○`, bei Problemen zusätzlich `⚠︎`.

Das Menü enthält:

- **Liste der auslösenden Mails**, gruppiert nach Kategorie: Betreff, Absender, Datum, Ordner (falls nicht Posteingang) und **Grund** (z. B. `Titel: Senior Director …`, `Linie Ebene 2: EVP …`, `Kunden-Domain philips.com`).
- **Klick auf eine Mail:** öffnet sie in Outlook im Web.
- **⌥ Option gedrückt halten:** Einträge werden zu „Quittieren: …“, damit lässt sich eine einzelne Mail quittieren.
- **Alarm löschen (alle quittieren):** blendet alle aktuellen Mails aus. Neue Mails lösen wieder Alarm aus.
- **Quittierte wieder anzeigen:** nimmt Quittierungen zurück.
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
- **`state.json`** – Status (`ok`/`auth`), Zeitpunkt der Prüfung und Liste der Treffer.
- **`dismissed.json`** – IDs quittierter Mails. Bereinigt sich selbst, sobald Mails gelesen sind.

## Projektstruktur

| Datei | Zweck |
|---|---|
| `src/MailStrip.swift` | Balken (ein Fenster pro Bildschirm), Animation, Menü, Quittieren |
| `scripts/MailStrip-Common.ps1` | Pfade, Logging, Status schreiben, Anmeldung, Managerliste |
| `scripts/MailStrip-Checker.ps1` | Hintergrunddienst: prüft alle 60 s den Posteingang |
| `scripts/Login.ps1` | Interaktive Anmeldung + Aktualisierung der Managerliste |
| `config/config.json` | Vorlage der Einstellungen |
| `install.sh` | Prüft/installiert Voraussetzungen, komplette Einrichtung inkl. Autostart |
| `INSTALL.md` | Installationsanleitung |
| `uninstall.sh` | Entfernt Autostart und optional alle Daten |

## Installation / Update

Ausführliche Schritt-für-Schritt-Anleitung: **[INSTALL.md](INSTALL.md)**

Voraussetzungen: Xcode Command Line Tools (`swiftc`) und PowerShell (`pwsh`). **Keine Admin-Rechte nötig.**

```bash
cd ~/Documents/Sources/mailstrip
git pull            # bei Update
./install.sh
```

Der Installer prüft die Voraussetzungen, stoppt alte Instanzen, kopiert alles nach `~/Library/Application Support/MailStrip`, baut die App, meldet dich per Device-Code an und richtet zwei LaunchAgents ein. Danach **startet alles nach jedem Neustart/Login automatisch**. Eine vorhandene `config.json` bleibt erhalten; neue Einstellungen werden ergänzt.

## Konfiguration

Datei: `~/Library/Application Support/MailStrip/config.json`. Änderungen wirken beim nächsten Durchlauf, **kein Neustart nötig**.

| Schlüssel | Bedeutung |
|---|---|
| `customerDomains` | Domains, die als Kunde gelten (grün). Subdomains zählen mit. |
| `internalDomains` | Nur für diese Domains wird nach Management-Titeln gesucht. |
| `managementTitlePatterns` | Regex-Muster für Jobtitel, die rot werden (in JSON `\\b` statt `\b`). |
| `extraManagementAddresses` | Zusätzliche Adressen, die immer rot sind. |
| `intervalSeconds` | Prüfintervall (Standard 60). |
| `lookbackHours` | Nur ungelesene Mails der letzten N **Arbeitsstunden** zählen (Standard 24). Wochenenden werden übersprungen: Montag 9:00 prüft ab Freitag 9:00. |
| `ignoreFolders` | Ordner, die nicht geprüft werden. Ordnername (`"Newsletter"`) oder Pfad (`"Inbox/Jira"`); Unterordner werden mit ignoriert. Groß/Klein egal. |
| `folderMapRefreshMinutes` | Wie oft die Ordnerstruktur neu geladen wird (Standard 15). Neue Ordner werden zusätzlich sofort erkannt. |
| `workDays` | Tage, an denen geprüft wird (englische Namen, Standard Mo–Fr). An anderen Tagen gibt es keinen Balken. |
| `managerListRefreshDays` | Managerliste wird nach N Tagen neu geladen (Standard 7). |
| `managerChainMaxLevels` | Maximale Ebenen nach oben in deiner Linie. |

## Code-Erklärung

### Swift-App (`src/MailStrip.swift`)

- **`Category`**: `management`, `linemanager`, `customer`. Die Reihenfolge bestimmt die Farbreihenfolge.
- **`MailItem` / `StatusFile`**: Abbild von `state.json`, gelesen mit `Codable`.
- **`StripWindow`**: randloses, transparentes Fenster ganz oben (`level = .screenSaver`, `ignoresMouseEvents`, auf allen Spaces). Ist standardmäßig **unsichtbar**.
  - **Puls**: `CAKeyframeAnimation` auf `opacity`, dunkel → hell → dunkel in 3 s.
  - **Farbwechsel**: zweite Keyframe-Animation auf `backgroundColor` mit `calculationMode = .discrete`. Die Dauer ist Anzahl Farben × 3 s, so springt die Farbe immer am dunkelsten Punkt.
- **`AppDelegate`**:
  - `refresh()` liest `state.json` alle 2 s, aber dekodiert nur bei Änderung.
  - `update()` blendet die Fenster ein/aus und startet die Animation nur neu, wenn sich die Kategorien ändern.
  - `menuNeedsUpdate` baut das Menü bei jedem Öffnen neu. Jede Mail hat einen alternativen Eintrag (`isAlternate`, ⌥), der sie quittiert.
  - `problemText()` erkennt fehlende Anmeldung und veraltete Daten (> 5 min) → `⚠︎`.
  - `pruneDismissed()` entfernt IDs gelesener Mails aus `dismissed.json`, aber nur bei Status `ok`.

### Gemeinsame Funktionen (`scripts/MailStrip-Common.ps1`)

- **`Write-StripStatus`**: schreibt `state.json` atomar (tmp-Datei + Umbenennen).
- **`Connect-MailStrip`**: Anmeldung mit `Mail.Read` und `User.Read.All`. Das Token wird im Benutzer-Cache gespeichert (`-ContextScope CurrentUser`).
- **`Update-ManagerList`**: holt deine Kette nach oben (Abbruch an der Spitze, weil der CEO sein eigener Manager ist) und alle internen Konten mit passendem Jobtitel. Speichert alles in `management.json`.
- **`Get-FolderMap`**: lädt den kompletten Ordnerbaum rekursiv und markiert ausgeschlossene Ordner (Standardordner + `ignoreFolders`, vererbt an Unterordner).
- **`Test-WorkDay` / `Get-LookbackStart`**: Arbeitstag prüfen und Beginn des Prüfzeitraums berechnen (Stunden an freien Tagen zählen nicht).
- **`Read-ManagerList`**: liefert den Line Manager und ein Wörterbuch *Adresse → Grund* für Rot.

### Checker (`scripts/MailStrip-Checker.ps1`)

- **`Get-InboxItems`**: lädt mit **einem** Aufruf (`/me/messages`) alle ungelesenen Mails der letzten 24 Arbeitsstunden aus allen Ordnern (nur `id`, `from`, `subject`, `receivedDateTime`, `webLink`, `parentFolderId`). Mails in ausgeschlossenen Ordnern werden verworfen, die übrigen einer Kategorie mit Grund und Ordner zugeordnet.
- **Hauptschleife**: an freien Tagen leere Liste schreiben und pausieren, sonst anmelden → Managerliste ggf. aktualisieren → prüfen → `state.json` → 60 s warten. Bei Änderungen wird jeder Treffer mit Grund geloggt. Kurzzeitige Fehler lassen den letzten Stand stehen.

### Autostart (`install.sh`)

| Label | Programm | Neustart |
|---|---|---|
| `com.andreasbrolund.mailstrip` | Swift-App | nur nach Absturz |
| `com.andreasbrolund.mailstrip.checker` | `pwsh MailStrip-Checker.ps1` | immer, frühestens nach 30 s |

## Fehlersuche

| Symptom | Ursache / Lösung |
|---|---|
| Alarm, aber unklar warum | Menü öffnen: Grund steht unter jeder Mail. Oder `checker.log` ansehen. |
| Falsche Person rot | Titel-Muster in `config.json` anpassen → **Managerliste jetzt aktualisieren** |
| `⚠︎ Anmeldung nötig` | Menü **Anmelden bei Microsoft …** |
| `⚠︎ Letzte Prüfung …` | Checker läuft nicht: `launchctl list \| grep mailstrip`, Log prüfen |
| Rohdaten ansehen | `cat ~/Library/Application\ Support/MailStrip/state.json` |
| Log live | `tail -f ~/Library/Logs/MailStrip/checker.log` |

## Bekannte Grenzen

- Mails öffnen sich in **Outlook im Web**, nicht in der Outlook-App.
- Bei weitergeleiteten Mails zählt die weiterleitende Person als Absender.
- Wie lange das Token gültig bleibt, hängt von den Cerence-Richtlinien ab.

## Deinstallation

```bash
./uninstall.sh
```
