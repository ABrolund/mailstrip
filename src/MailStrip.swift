// =============================================================================
// MailStrip.swift
// -----------------------------------------------------------------------------
// Zweck:
//   Zeigt einen schmalen, langsam pulsierenden Farbstreifen am oberen Rand
//   JEDES Bildschirms – aber NUR, wenn ungelesene Mails von Kunden oder
//   Management im Posteingang liegen. Sonst ist kein Balken zu sehen.
//
//   Farben:  rot = Management, gelb = Line Manager, grün = Kunde.
//   Treffen mehrere zu, wechseln die Farben nacheinander (ein Puls je Farbe).
//
// Zusammenspiel:
//   Die App liest nur state.json. Geschrieben wird die Datei vom
//   PowerShell-Skript MailStrip-Checker.ps1 (alle 60 s). Die App selbst
//   hat keinen Zugriff auf Mails oder Microsoft Graph.
//
// Menü (Symbol in der Menüleiste):
//   - Liste aller auslösenden Mails (Betreff, Absender, Datum, Ordner, Grund)
//   - Klick auf eine Mail öffnet sie in Outlook im Web
//   - ⌥ Option gedrückt halten: einzelne Mail quittieren
//   - "Alarm löschen": alle aktuellen Mails quittieren
//
// Bauen:
//   swiftc -O MailStrip.swift -o MailStrip   (macht install.sh automatisch)
// =============================================================================

// Ablauf zur Laufzeit:
//   1. Start: Fenster je Bildschirm anlegen (unsichtbar), Menüleisten-Symbol setzen.
//   2. Alle 2 s: state.json lesen -> sichtbare Mails bestimmen.
//   3. Keine Mails      -> Fenster ausblenden, Symbol ○.
//      Mails vorhanden  -> Farben bestimmen, Animation starten, Fenster zeigen.
//   4. Menü öffnen      -> Liste wird aus dem aktuellen Stand neu gebaut.
//   5. Quittieren       -> Mail-ID in dismissed.json, Balken sofort aktualisiert.
//
// Warum eine Datei statt direkter Kommunikation?
//   - Beide Teile können unabhängig neu starten.
//   - state.json lässt sich zur Fehlersuche einfach ansehen:
//     cat ~/Library/Application\ Support/MailStrip/state.json

import Cocoa        // Fenster, Menüleiste, Farben
import QuartzCore   // CALayer + Keyframe-Animationen für Puls und Farbwechsel

// -----------------------------------------------------------------------------
// Kategorien, wie sie der Checker in state.json schreibt.
// Die Reihenfolge der Fälle ist zugleich die Anzeigereihenfolge (rot zuerst).
// -----------------------------------------------------------------------------
// Codable: Wert wird direkt aus dem JSON-Text gelesen ("management" usw.).
// CaseIterable: erlaubt Category.allCases für die feste Reihenfolge.
enum Category: String, Codable, CaseIterable {
    case management    // höheres Management -> rot
    case linemanager   // direkter Vorgesetzter -> gelb
    case customer      // Kunden-Domain -> grün
}

// Farbe je Kategorie.
// Systemfarben passen sich automatisch an Hell-/Dunkelmodus an.
func color(for c: Category) -> NSColor {
    switch c {
    case .management:  return .systemRed
    case .linemanager: return .systemYellow
    case .customer:    return .systemGreen
    }
}

// Überschrift je Kategorie im Menü.
func label(for c: Category) -> String {
    switch c {
    case .management:  return "Management"
    case .linemanager: return "Line Manager"
    case .customer:    return "Kunde"
    }
}

// -----------------------------------------------------------------------------
// Datenmodell von state.json (muss zu Write-StripStatus im Checker passen).
// Optionale Felder, weil z. B. ein Betreff in Outlook leer sein kann.
// -----------------------------------------------------------------------------
struct MailItem: Codable {
    let id: String          // Graph-ID der Mail (zum Quittieren)
    let category: Category
    let name: String?       // Anzeigename des Absenders
    let address: String?    // Mail-Adresse des Absenders
    let subject: String?
    let received: String?   // ISO-8601 in UTC, z. B. 2026-10-26T13:42:13Z
    let webLink: String?    // Link zu Outlook im Web
    let reason: String?     // warum diese Mail ausgelöst hat
    let folder: String?     // Ordnerpfad, z. B. "Inbox/Projekte"
}

// Gesamter Inhalt von state.json. Ist die Liste leer, gibt es keinen Balken.
struct StatusFile: Codable {
    let status: String      // "ok" oder "auth" (Anmeldung nötig)
    let updated: String?    // Zeitpunkt der letzten Prüfung (UTC)
    let message: String?    // Fehlertext, falls vorhanden
    let items: [MailItem]
}

// -----------------------------------------------------------------------------
// Einstellungen für die Darstellung.
// -----------------------------------------------------------------------------
// Werte hier ändern und neu bauen (./install.sh), um das Aussehen anzupassen.
let stripHeight: CGFloat = 6       // Höhe des Streifens in Punkten
let pulsePeriod: Double  = 3.0     // ein Puls dauert immer 3 s (immer langsam)
let minAlpha: Double     = 0.25    // dunkelster Punkt des Pulses
let staleSeconds: Double = 300     // älter als 5 min -> Warnsymbol in der Menüleiste

// -----------------------------------------------------------------------------
// Feste Pfade. Alles im Benutzerordner -> keine Admin-Rechte nötig.
// -----------------------------------------------------------------------------
let home          = FileManager.default.homeDirectoryForCurrentUser
let appDir        = home.appendingPathComponent("Library/Application Support/MailStrip")
let stateURL      = appDir.appendingPathComponent("state.json")      // vom Checker
let dismissedURL  = appDir.appendingPathComponent("dismissed.json")  // quittierte Mail-IDs
let refreshURL    = appDir.appendingPathComponent("refresh-now")     // Signal: Managerliste neu
let loginURL      = appDir.appendingPathComponent("Login.command")   // Terminal-Anmeldung
let logURL        = home.appendingPathComponent("Library/Logs/MailStrip/checker.log")

// Formatierer für Datumsangaben (einmal anlegen, das Anlegen ist teuer).
// isoParser liest die UTC-Zeit aus dem Checker, shortDate zeigt sie lokal an.
let isoParser = ISO8601DateFormatter()
let shortDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM. HH:mm"; return f }()

// ISO-Zeit aus state.json -> "26.10. 14:42" in lokaler Zeit.
func formatDate(_ s: String?) -> String {
    guard let s = s, let d = isoParser.date(from: s) else { return s ?? "" }
    return shortDate.string(from: d)
}

// =============================================================================
// Ein randloses, durchsichtiges Fenster pro Bildschirm, das nur den Balken
// enthält. Liegt über allem, auf allen Spaces, Klicks gehen hindurch.
// =============================================================================
// Eigene Unterklasse, damit Fenster und Layer zusammen verwaltet werden.
final class StripWindow: NSWindow {
    let bar = CALayer()   // die farbige Fläche

    init(screen: NSScreen) {
        // Rechteck ganz oben (macOS-Koordinaten: y wächst nach oben).
        // screen.frame enthält die Menüleiste -> Balken liegt darüber.
        let f = screen.frame
        let rect = NSRect(x: f.minX, y: f.maxY - stripHeight, width: f.width, height: stripHeight)
        super.init(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)

        // --- Fenstereigenschaften ---
        isOpaque = false                  // Transparenz erlauben
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true         // Klicks gehen an das Fenster darunter
        level = .screenSaver              // über Menüleiste und Vollbild-Apps
        // Auf allen Spaces sichtbar, nicht per Cmd+Tab erreichbar, neben Vollbild-Apps.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false

        // Layer-basierte View, damit Core Animation flüssig (GPU) rendert.
        let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
        v.wantsLayer = true
        bar.frame = v.bounds
        bar.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(bar)
        contentView = v
        // Bewusst NICHT anzeigen – sichtbar erst, wenn es Alarme gibt.
    }

    // Farben setzen und Animationen starten.
    //   Puls:        Deckkraft dunkel -> hell -> dunkel, Dauer pulsePeriod.
    //   Farbwechsel: bei mehreren Farben springt die Farbe jeweils am
    //                dunkelsten Punkt weiter -> ein Puls pro Farbe.
    // Wird nur aufgerufen, wenn sich die Kategorien ändern (siehe update()).
    func apply(colors: [NSColor]) {
        // Alte Animationen entfernen, sonst laufen mehrere übereinander.
        bar.removeAllAnimations()
        guard let first = colors.first else { return }
        bar.backgroundColor = first.cgColor

        // Puls beginnt dunkel, damit der Farbwechsel unauffällig im Dunkeln passiert.
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [minAlpha, 1.0, minAlpha]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = pulsePeriod
        pulse.repeatCount = .infinity
        // Weiches Ein- und Ausblenden statt linearem Verlauf.
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(name: .easeInEaseOut)]
        bar.add(pulse, forKey: "pulse")

        // Nur bei mehreren Kategorien: Farben nacheinander durchlaufen.
        // Gesamtdauer = Anzahl Farben × Pulsdauer -> Puls und Farbe bleiben synchron.
        if colors.count > 1 {
            let n = colors.count
            let cycle = CAKeyframeAnimation(keyPath: "backgroundColor")
            cycle.values = colors.map { $0.cgColor }
            // "discrete": harte Sprünge; keyTimes braucht dafür n+1 Einträge.
            cycle.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
            cycle.calculationMode = .discrete
            cycle.duration = pulsePeriod * Double(n)
            cycle.repeatCount = .infinity
            bar.add(cycle, forKey: "colors")
        }
    }
}

// =============================================================================
// App-Logik: state.json beobachten, Balken ein-/ausblenden, Menü bauen,
// Quittierungen verwalten.
// =============================================================================
// NSMenuDelegate wird für menuNeedsUpdate benötigt.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // --- Zustand der App ---
    var windows: [StripWindow] = []
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastData: Data?                  // zuletzt gelesener Dateiinhalt
    var state: StatusFile?               // letzter gültiger Inhalt
    var dismissed: Set<String> = []      // quittierte Mail-IDs
    var shown: [Category]? = nil         // aktuell angezeigte Kategorien (nil = noch nie)

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        // Reihenfolge: Quittierungen laden, Fenster bauen, dann ersten Stand lesen.
        loadDismissed()
        buildWindows()

        // Menüleisten-Eintrag. Das Menü wird bei jedem Öffnen neu gebaut
        // (menuNeedsUpdate), damit es immer den aktuellen Stand zeigt.
        // variableLength: Breite passt sich an (○, ●● 3, ⚠︎ …).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        // Alle 2 s prüfen, ob sich state.json geändert hat (eine kleine Datei).
        // [weak self] verhindert einen Referenzzyklus zwischen Timer und App.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // Monitor an-/abgesteckt -> Fenster neu bauen und Zustand neu anwenden.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.buildWindows()
                self?.shown = nil        // erzwingt erneutes Anwenden
                self?.update()
        }
    }

    // Ein Streifen-Fenster pro angeschlossenem Bildschirm.
    // Alte Fenster werden geschlossen (z. B. von abgezogenen Monitoren).
    func buildWindows() {
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map { StripWindow(screen: $0) }
    }

    // ---------------------------------------------------------------- Daten --

    // state.json lesen, aber nur bei Änderung neu auswerten.
    func refresh() {
        // Vergleich mit lastData spart unnötiges Dekodieren bei gleichem Inhalt.
        // Ist die Datei kaputt (Dekodierfehler), bleibt der letzte gültige Stand.
        if let data = try? Data(contentsOf: stateURL), data != lastData {
            lastData = data
            if let s = try? JSONDecoder().decode(StatusFile.self, from: data) {
                state = s
                pruneDismissed()
            }
        }
        update()   // immer: aktualisiert z. B. das Warnsymbol bei veralteten Daten
    }

    // Mails, die nicht quittiert sind.
    // Quittierte Mails werden ausgeblendet, bleiben aber in state.json.
    func visibleItems() -> [MailItem] {
        (state?.items ?? []).filter { !dismissed.contains($0.id) }
    }

    // Problemtext für Menüleiste/Menü, oder nil, wenn alles in Ordnung ist.
    func problemText() -> String? {
        // Drei Fälle: keine Datei, Anmeldung nötig, Daten zu alt.
        guard let s = state else { return "Noch keine Daten vom Checker" }
        if s.status == "auth" { return "Anmeldung nötig" }
        if let u = s.updated, let d = isoParser.date(from: u),
           Date().timeIntervalSince(d) > staleSeconds {
            return "Letzte Prüfung \(shortDate.string(from: d)) – Checker läuft nicht?"
        }
        return nil
    }

    // ------------------------------------------------------------- Anzeige --

    // Balken ein-/ausblenden und Menüleisten-Symbol setzen.
    // Wird alle 2 s aufgerufen, ist aber günstig: Animation nur bei Änderung.
    func update() {
        // Kategorien in fester Reihenfolge (rot, gelb, grün), nur wenn vorhanden.
        let items = visibleItems()
        let cats = Category.allCases.filter { c in items.contains { $0.category == c } }

        // Animation nur neu starten, wenn sich die Kategorien geändert haben.
        if shown != cats {
            shown = cats
            if cats.isEmpty {
                windows.forEach { $0.orderOut(nil) }        // kein Alarm -> kein Balken
            } else {
                let cols = cats.map { color(for: $0) }
                windows.forEach { $0.apply(colors: cols); $0.orderFrontRegardless() }
            }
        }

        // Menüleiste: farbige Punkte je Kategorie + Anzahl, ○ wenn nichts anliegt.
        // Schrift der Menüleiste verwenden, damit das Symbol nicht zu groß wirkt.
        let font = NSFont.menuBarFont(ofSize: 0)
        let t = NSMutableAttributedString()
        if problemText() != nil { t.append(NSAttributedString(string: "⚠︎ ", attributes: [.font: font])) }
        if cats.isEmpty {
            t.append(NSAttributedString(string: "○", attributes: [.font: font]))
        } else {
            for c in cats {
                t.append(NSAttributedString(string: "●", attributes: [.font: font, .foregroundColor: color(for: c)]))
            }
            t.append(NSAttributedString(string: " \(items.count)", attributes: [.font: font]))
        }
        statusItem.button?.attributedTitle = t
    }

    // ---------------------------------------------------------------- Menü --

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Menü komplett neu aufbauen – einfacher als einzelne Einträge zu ändern.
        menu.removeAllItems()
        // Hilfsfunktionen für kompakte Menüeinträge.
        func action(_ title: String, _ sel: Selector) {
            menu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
        }
        func info(_ title: String) {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }

        // Hinweis bei Problemen ganz oben.
        if let p = problemText() { info("⚠︎ \(p)"); menu.addItem(.separator()) }

        let items = visibleItems()
        if items.isEmpty { info("Keine Alarme") }

        // Je Kategorie eine Überschrift und darunter die Mails.
        for c in Category.allCases {
            let list = items.filter { $0.category == c }
            if list.isEmpty { continue }

            // Überschrift: farbiger Punkt + Name + Anzahl, nicht anklickbar.
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let h = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color(for: c)])
            h.append(NSAttributedString(string: "\(label(for: c)) (\(list.count))",
                                        attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
            header.attributedTitle = h
            header.isEnabled = false
            menu.addItem(header)

            for it in list {
                // Normaler Eintrag: Klick öffnet die Mail.
                let open = NSMenuItem(title: "", action: #selector(openMail(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = it.webLink
                open.attributedTitle = itemTitle(it)
                // Tooltip (Maus kurz stehen lassen) zeigt Adresse und Grund vollständig.
                open.toolTip = "\(it.address ?? "")\nOrdner: \(it.folder ?? "-")\nGrund: \(it.reason ?? "-")"
                open.indentationLevel = 1
                menu.addItem(open)

                // Alternativer Eintrag (sichtbar mit ⌥ Option): Mail quittieren.
                // isAlternate + .option: ersetzt den Eintrag darüber, solange ⌥ gedrückt ist.
            let dis = NSMenuItem(title: "Quittieren: \(short(it.subject, 60))",
                                     action: #selector(dismissOne(_:)), keyEquivalent: "")
                dis.target = self
                dis.representedObject = it.id
                dis.isAlternate = true
                dis.keyEquivalentModifierMask = .option
                dis.indentationLevel = 1
                menu.addItem(dis)
            }
        }

        // --- Aktionen unterhalb der Liste ---
        menu.addItem(.separator())
        if !items.isEmpty {
            action("Alarm löschen (alle quittieren)", #selector(dismissAll))
            info("Tipp: ⌥ gedrückt halten = einzeln quittieren")
        }
        if !dismissed.isEmpty { action("Quittierte wieder anzeigen (\(dismissed.count))", #selector(resetDismissed)) }
        menu.addItem(.separator())
        // Verwaltungsfunktionen.
        action("Anmelden bei Microsoft …",          #selector(login))
        action("Managerliste jetzt aktualisieren",  #selector(refreshManagers))
        action("Log öffnen",                        #selector(openLog))
        menu.addItem(.separator())
        // Normales Ende -> launchd startet erst beim nächsten Login wieder.
        menu.addItem(withTitle: "MailStrip beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // Zweizeiliger Menütext: Betreff fett, darunter Absender · Datum · Grund.
    func itemTitle(_ it: MailItem) -> NSAttributedString {
        // Zeilenumbruch im Titel erzeugt einen zweizeiligen Menüeintrag.
        let t = NSMutableAttributedString(string: short(it.subject, 70),
                                          attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        // Ordner nur zeigen, wenn es nicht der Posteingang ist (spart Platz).
        let f = it.folder ?? ""
        let folderPart = (f.isEmpty || ["inbox", "posteingang"].contains(f.lowercased())) ? "" : "  ·  📁 \(f)"
        let sub = "\n\(it.name ?? it.address ?? "?")  ·  \(formatDate(it.received))\(folderPart)  ·  \(it.reason ?? "")"
        t.append(NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                              .foregroundColor: NSColor.secondaryLabelColor]))
        return t
    }

    // Text kürzen, damit das Menü nicht über den Bildschirm geht.
    func short(_ s: String?, _ max: Int) -> String {
        // Leerer oder fehlender Betreff -> Platzhalter.
        let s = (s?.isEmpty == false) ? s! : "(kein Betreff)"
        return s.count > max ? String(s.prefix(max)) + "…" : s
    }

    // ---------------------------------------------------------- Aktionen --

    // Mail in Outlook im Web öffnen (Standardbrowser).
    // webLink kommt von Graph; Outlook für Mac bietet keinen zuverlässigen
    // Link zum direkten Öffnen einer bestimmten Mail.
    @objc func openMail(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
    // Eine Mail quittieren -> verschwindet aus Balken und Liste.
    @objc func dismissOne(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { dismissed.insert(id); saveDismissed(); update() }
    }
    // Alle aktuell sichtbaren Mails quittieren ("Alarm löschen").
    // Neue Mails, die später kommen, lösen wieder Alarm aus.
    @objc func dismissAll() {
        visibleItems().forEach { dismissed.insert($0.id) }
        saveDismissed(); update()
    }
    // Quittierungen zurücknehmen.
    @objc func resetDismissed() { dismissed.removeAll(); saveDismissed(); update() }
    // Öffnet Terminal mit Device-Code-Anmeldung (Login.command).
    @objc func login()           { NSWorkspace.shared.open(loginURL) }
    // Leere Signaldatei; der Checker sieht sie beim nächsten Durchlauf.
    @objc func refreshManagers() { FileManager.default.createFile(atPath: refreshURL.path, contents: nil) }
    // Öffnet checker.log in der Konsole-App.
    @objc func openLog()         { NSWorkspace.shared.open(logURL) }

    // ------------------------------------------------------- Quittierungen --
    // Gespeichert als JSON-Liste von Mail-IDs -> überlebt Neustarts.

    // Fehlt die Datei oder ist sie defekt, startet die Liste leer.
    func loadDismissed() {
        if let d = try? Data(contentsOf: dismissedURL),
           let ids = try? JSONDecoder().decode([String].self, from: d) { dismissed = Set(ids) }
    }
    // .atomic: erst temporär schreiben, dann ersetzen.
    func saveDismissed() {
        if let d = try? JSONEncoder().encode(Array(dismissed)) { try? d.write(to: dismissedURL, options: .atomic) }
    }
    // IDs entfernen, die nicht mehr ungelesen im Posteingang sind (Datei bleibt klein).
    // Nur bei status "ok" – bei Anmeldeproblemen ist die Liste leer und unzuverlässig.
    // Wird nach jedem erfolgreichen Lesen von state.json aufgerufen.
    func pruneDismissed() {
        guard let s = state, s.status == "ok" else { return }
        let current = Set(s.items.map { $0.id })
        let kept = dismissed.intersection(current)
        if kept != dismissed { dismissed = kept; saveDismissed() }
    }
}

// -----------------------------------------------------------------------------
// Einstiegspunkt. ".accessory" = kein Dock-Symbol, nur Menüleiste.
// Die Delegate-Instanz muss global gehalten werden, sonst wird sie freigegeben.
// -----------------------------------------------------------------------------
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
