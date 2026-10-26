# MailStrip

Ein pulsierender Farbstreifen am oberen Bildschirmrand (macOS), der anzeigt, **von wem ungelesene Mails** im Outlook-Posteingang liegen.

| Farbe | Bedeutung | Menüleiste |
|---|---|---|
| 🔵 Blau (langsam) | nichts Wichtiges ungelesen | ● |
| 🟢 Grün | Mail von einem Kunden | ● K |
| 🟡 Gelb | Mail vom direkten Line Manager | ● L |
| 🔴 Rot (schnell) | Mail von höherem Management (Linie ab Ebene 2, Director, VP, C-Level …) | ● M |
| ⚪ Grau | Anmeldung läuft / nötig oder Verbindungsfehler | ● ? |

Bei mehreren ungelesenen Mails gilt: **Rot > Gelb > Grün > Blau**. Sobald die Mail gelesen ist, geht der Balken beim nächsten Prüfdurchlauf zurück.

---

## Architektur

```
┌──────────────────────────┐   schreibt    ┌───────────┐   liest alle 2 s   ┌────────────────────┐
│ MailStrip-Checker.ps1    │ ────────────▶ │ state.txt │ ◀───────────────── │ MailStrip (Swift)  │
│ (PowerShell, alle 60 s)  │               └───────────┘                    │ Balken + Menü      │
│  • Microsoft Graph       │                                                └────────────────────┘
│  • management.json (1×/Woche)                                                     
└──────────────────────────┘
        ▲ beide werden von launchd (LaunchAgents) beim Login gestartet
```

Die beiden Teile sind bewusst getrennt:

- **Swift-App** – nur Anzeige. Kein Zugriff auf Mails, keine Anmeldung. Liest `state.txt`.
- **PowerShell-Checker** – die gesamte Logik: Anmeldung, Managerliste, Mail-Prüfung.

Verbindendes Element ist eine einzige Textdatei mit einem Wort (`idle`, `customer`, `linemanager`, `management`, `auth`). Dadurch lässt sich jeder Teil einzeln testen.

## Projektstruktur

| Datei | Zweck |
|---|---|
| `src/MailStrip.swift` | Balken-App (ein Fenster pro Bildschirm, Puls-Animation, Menü) |
| `scripts/MailStrip-Common.ps1` | Gemeinsame Funktionen: Pfade, Logging, Anmeldung, Managerliste |
| `scripts/MailStrip-Checker.ps1` | Hintergrunddienst: prüft alle 60 s den Posteingang |
| `scripts/Login.ps1` | Interaktive Anmeldung + sofortige Aktualisierung der Managerliste |
| `config/config.json` | Vorlage der Einstellungen (wird nur bei Erstinstallation kopiert) |
| `install.sh` | Komplette Einrichtung inkl. Autostart |
| `uninstall.sh` | Entfernt Autostart und optional alle Daten |

## Installation

Voraussetzungen: Xcode Command Line Tools (`swiftc`), PowerShell (`pwsh`). **Keine Admin-Rechte nötig.**

```bash
git clone <REPO-URL> ~/mailstrip
cd ~/mailstrip
./install.sh
```

Der Installer

1. prüft `swiftc`, `pwsh` und installiert fehlende Graph-Module (`Microsoft.Graph.Authentication`, `.Users`, `.Mail`) für den aktuellen Benutzer,
2. stoppt alte Instanzen (auch manuell gestartete Tests),
3. kopiert alles nach `~/Library/Application Support/MailStrip`,
4. baut die Swift-App,
5. startet die **Anmeldung per Device-Code** und lädt die Managerliste,
6. legt zwei LaunchAgents in `~/Library/LaunchAgents` an und startet sie.

Danach laufen Balken und Prüfung und **starten nach jedem Neustart/Login automatisch**. `./install.sh` kann jederzeit erneut ausgeführt werden (z. B. nach `git pull`); deine `config.json` bleibt dabei erhalten.

## Konfiguration

Datei: `~/Library/Application Support/MailStrip/config.json` – Änderungen wirken beim nächsten Prüfdurchlauf, **kein Neustart nötig**.

| Schlüssel | Bedeutung |
|---|---|
| `customerDomains` | Domains, die als Kunde gelten (grün). Subdomains zählen mit. |
| `internalDomains` | Nur für diese Domains wird nach Management-Titeln gesucht. |
| `managementTitlePatterns` | Regex-Muster für Jobtitel, die rot werden (in JSON `\\b` statt `\b`). |
| `extraManagementAddresses` | Zusätzliche Adressen, die immer rot sind. |
| `intervalSeconds` | Prüfintervall (Standard 60). |
| `managerListRefreshDays` | Alter der Managerliste, ab dem neu geladen wird (Standard 7). |
| `managerChainMaxLevels` | Maximale Ebenen nach oben in deiner Linie. |

## Menü (● in der Menüleiste)

- **Anmelden bei Microsoft …** – öffnet ein Terminal mit Device-Code-Anmeldung, aktualisiert die Managerliste und startet den Checker neu.
- **Managerliste jetzt aktualisieren** – erzwingt die Aktualisierung beim nächsten Durchlauf.
- **Log öffnen** – zeigt `checker.log` in der Konsole-App.
- **Test: …** – setzt die Farbe kurz von Hand (wird nach max. 60 s vom Checker überschrieben).
- **Balken beenden** – bis zum nächsten Login. (Abstürze werden dagegen automatisch neu gestartet.)

## Code-Erklärung

### Swift-App (`src/MailStrip.swift`)

- **`StripState`** – die fünf Zustände; der Name entspricht genau dem Text in `state.txt`.
- **`style(for:)`** – ordnet jedem Zustand Farbe, Pulsdauer und minimale Deckkraft zu.
- **`StripWindow`** – randloses, transparentes Fenster ganz oben auf einem Bildschirm. Wichtige Eigenschaften:
  - `level = .screenSaver` → liegt über Menüleiste und Vollbild-Apps,
  - `ignoresMouseEvents = true` → Klicks gehen durch,
  - `canJoinAllSpaces` → auf allen Schreibtischen sichtbar.
  Das Pulsieren ist eine `CABasicAnimation` auf `opacity`, die endlos hin und zurück läuft (GPU-beschleunigt, praktisch keine CPU-Last).
- **`AppDelegate`** – baut ein Fenster pro Bildschirm, liest `state.txt` alle 2 s und reagiert auf an-/abgesteckte Monitore (`didChangeScreenParametersNotification`).
- `setActivationPolicy(.accessory)` → kein Dock-Symbol.

### Gemeinsame Funktionen (`scripts/MailStrip-Common.ps1`)

- **`Set-StripState`** – schreibt erst eine `.tmp`-Datei und benennt sie dann um, damit die App nie eine halbe Datei liest.
- **`Connect-MailStrip`** – meldet sich mit `Mail.Read` und `User.Read.All` an. `-ContextScope CurrentUser` speichert das Token im Benutzer-Cache, damit es nach einem Neustart wiederverwendet werden kann.
- **`Test-ManagerListDue`** – Liste fehlt, ist älter als 7 Tage oder wurde über das Menü angefordert.
- **`Update-ManagerList`** – holt
  1. deine **Kette nach oben** über `Get-MgUserManager` (Abbruch, wenn eine Person erneut auftaucht – der CEO ist im Verzeichnis sein eigener Manager),
  2. **alle aktiven internen Konten**, deren Jobtitel auf ein Muster passt.
  Wird nichts gefunden, bleibt die alte Liste erhalten.
- **`Read-ManagerList`** – baut daraus `LineManager` (Ebene 1, gelb) und ein `HashSet` für Rot (Ebene 2+, Titel-Treffer, Zusatzadressen). Der Line Manager wird aus Rot entfernt, damit er gelb bleibt, auch wenn sein Titel passt.

### Checker (`scripts/MailStrip-Checker.ps1`)

- **`Get-InboxState`** – lädt bis zu 100 ungelesene Mails im Posteingang, aber nur das Feld `from`. Jede Mail wird eingestuft; der höchste Rang gewinnt.
- **Hauptschleife** – anmelden → Managerliste ggf. aktualisieren → Posteingang prüfen → `state.txt` schreiben → 60 s warten. Bei Anmeldefehlern wird der Balken grau und beim nächsten Durchlauf neu angemeldet. Geloggt werden nur Zustandswechsel und Fehler.

### Autostart (`install.sh`)

Zwei **LaunchAgents** (laufen im Benutzerkontext, keine Admin-Rechte):

| Label | Programm | Neustart-Verhalten |
|---|---|---|
| `com.andreasbrolund.mailstrip` | Swift-App | nur nach Absturz (`SuccessfulExit = false`) |
| `com.andreasbrolund.mailstrip.checker` | `pwsh MailStrip-Checker.ps1` | immer (`KeepAlive`), frühestens nach 30 s |

## Fehlersuche

| Symptom | Ursache / Lösung |
|---|---|
| Balken bleibt **grau** | Token abgelaufen → Menü **Anmelden bei Microsoft …** |
| Kein Balken nach Neustart | `launchctl print gui/$(id -u)/com.andreasbrolund.mailstrip` prüfen; ggf. `./install.sh` erneut |
| Person falsch eingestuft | `management.json` ansehen, Muster in `config.json` anpassen, Menü **Managerliste jetzt aktualisieren** |
| Status der Dienste | `launchctl list \| grep mailstrip` |
| Log | `tail -f ~/Library/Logs/MailStrip/checker.log` |

## Bekannte Grenzen

- Geprüft wird nur der **Posteingang** – Mails, die Regeln in Unterordner verschieben, werden nicht erkannt.
- Bei weitergeleiteten Mails zählt die weiterleitende Person als Absender.
- Wie lange das gespeicherte Token gültig bleibt, hängt von den Cerence-Richtlinien ab (Conditional Access). Danach ist eine erneute Anmeldung über das Menü nötig.
- Neue Manager werden erst bei der nächsten wöchentlichen Aktualisierung erkannt (oder per Menü sofort).

## Deinstallation

```bash
./uninstall.sh
```
