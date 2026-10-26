// =============================================================================
// MailStrip.swift
// -----------------------------------------------------------------------------
// Zweck:
//   Zeichnet einen schmalen, pulsierenden Farbstreifen am oberen Rand JEDES
//   angeschlossenen Bildschirms. Die Farbe zeigt an, von wem ungelesene Mails
//   im Posteingang liegen (Kunde, Line Manager, höheres Management).
//
// Zusammenspiel:
//   Diese App liest NUR eine Textdatei (state.txt). Das Schreiben der Datei
//   übernimmt das PowerShell-Skript MailStrip-Checker.ps1. So bleibt die App
//   klein und braucht keinerlei Zugriff auf Mails oder Microsoft Graph.
//
// Bauen:
//   swiftc -O MailStrip.swift -o MailStrip   (macht install.sh automatisch)
// =============================================================================

import Cocoa        // Fenster, Menüleiste, Farben
import QuartzCore   // CALayer + CABasicAnimation für das Pulsieren

// -----------------------------------------------------------------------------
// Zustände, die in state.txt stehen können.
// Der rawValue ist exakt der Text in der Datei (Kleinbuchstaben).
// -----------------------------------------------------------------------------
enum StripState: String {
    case idle         // nichts Wichtiges ungelesen          -> blau
    case customer     // Mail von einer Kunden-Domain        -> grün
    case linemanager  // Mail vom direkten Vorgesetzten      -> gelb
    case management   // Mail von höherem Management         -> rot
    case auth         // Anmeldung läuft / nötig / Fehler    -> grau
}

// -----------------------------------------------------------------------------
// Darstellung pro Zustand:
//   color    = Farbe des Streifens
//   period   = Dauer eines kompletten Pulses in Sekunden (kleiner = hektischer)
//   minAlpha = dunkelster Punkt des Pulses (0 = unsichtbar, 1 = kein Puls)
// -----------------------------------------------------------------------------
struct Style { let color: NSColor; let period: Double; let minAlpha: Float }

func style(for s: StripState) -> Style {
    switch s {
    case .idle:        return Style(color: NSColor(calibratedRed: 0.2, green: 0.6, blue: 1.0, alpha: 1),
                                    period: 3.0, minAlpha: 0.25)          // ruhiges Blau
    case .customer:    return Style(color: .systemGreen,  period: 1.2, minAlpha: 0.15)
    case .linemanager: return Style(color: .systemYellow, period: 0.9, minAlpha: 0.15)
    case .management:  return Style(color: .systemRed,    period: 0.6, minAlpha: 0.10)
    case .auth:        return Style(color: .systemGray,   period: 4.0, minAlpha: 0.30)
    }
}

// Kurzes Symbol in der Menüleiste je Zustand (zur schnellen Kontrolle).
let menuTitles: [StripState: String] = [
    .idle: "●", .customer: "● K", .linemanager: "● L", .management: "● M", .auth: "● ?"
]

// -----------------------------------------------------------------------------
// Feste Pfade. Alles liegt im Benutzerordner -> keine Admin-Rechte nötig.
// -----------------------------------------------------------------------------
let stripHeight: CGFloat = 6   // Höhe des Streifens in Punkten
let home        = FileManager.default.homeDirectoryForCurrentUser
let appDir      = home.appendingPathComponent("Library/Application Support/MailStrip")
let stateURL    = appDir.appendingPathComponent("state.txt")      // vom Checker geschrieben
let refreshURL  = appDir.appendingPathComponent("refresh-now")    // Signal: Managerliste neu laden
let loginURL    = appDir.appendingPathComponent("Login.command")  // öffnet Terminal zur Anmeldung
let logURL      = home.appendingPathComponent("Library/Logs/MailStrip/checker.log")

// =============================================================================
// Ein randloses, durchsichtiges Fenster pro Bildschirm, das nur den Balken
// enthält. Es liegt über allem, ist auf allen Spaces sichtbar und lässt
// Mausklicks durch.
// =============================================================================
final class StripWindow: NSWindow {
    let bar = CALayer()   // die eigentliche farbige Fläche

    init(screen: NSScreen) {
        // Rechteck ganz oben am Bildschirm (macOS-Koordinaten: y wächst nach oben).
        // screen.frame enthält auch die Menüleiste -> Balken liegt darüber.
        let f = screen.frame
        let rect = NSRect(x: f.minX, y: f.maxY - stripHeight, width: f.width, height: stripHeight)
        super.init(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false                  // Transparenz erlauben
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true         // Klicks gehen an das Fenster darunter
        level = .screenSaver              // über Menüleiste und Vollbild-Apps
        // Auf allen Spaces sichtbar, nicht per Cmd+Tab erreichbar,
        // bleibt auch neben Vollbild-Apps stehen.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false

        // Layer-basierte View, damit Core Animation den Puls flüssig rendert.
        let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
        v.wantsLayer = true
        bar.frame = v.bounds
        bar.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(bar)
        contentView = v
        orderFrontRegardless()            // anzeigen, ohne die App zu aktivieren
    }

    // Farbe setzen und Puls-Animation (Deckkraft hin und her) neu starten.
    func apply(_ s: Style) {
        bar.removeAllAnimations()
        bar.backgroundColor = s.color.cgColor
        // Animation der Deckkraft: 1.0 -> minAlpha -> 1.0 -> …
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = s.minAlpha
        a.duration = s.period / 2         // halber Puls hin, halber zurück
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(a, forKey: "pulse")
    }
}

// =============================================================================
// App-Logik: Fenster verwalten, state.txt beobachten, Menüleisten-Menü.
// =============================================================================
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [StripWindow] = []
    var current: StripState = .auth      // Startzustand grau, bis der Checker meldet
    var statusItem: NSStatusItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Ordner anlegen, falls die App vor dem Installer gestartet wurde.
        // Ab hier: Fenster bauen, Menü bauen, ersten Zustand anzeigen.
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        buildWindows()
        buildMenu()
        readState(force: true)

        // Alle 2 Sekunden state.txt lesen. Das ist billig (eine kleine Datei)
        // und deutlich einfacher als Datei-Events.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.readState()
        }

        // Monitor an-/abgesteckt oder Auflösung geändert -> Fenster neu bauen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.buildWindows()
                self?.applyAll()
        }
    }

    // Für jeden aktuell angeschlossenen Bildschirm ein Streifen-Fenster.
    func buildWindows() {
        // Alte Fenster schließen (z. B. von einem abgezogenen Monitor).
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map { StripWindow(screen: $0) }
    }

    // Aktuellen Zustand auf alle Fenster und das Menüleisten-Symbol anwenden.
    func applyAll() {
        // Stil des aktuellen Zustands holen.
        let s = style(for: current)
        windows.forEach { $0.apply(s) }
        statusItem?.button?.title = menuTitles[current] ?? "●"
    }

    // state.txt lesen; unbekannter oder fehlender Inhalt zählt als "auth" (grau).
    func readState(force: Bool = false) {
        // Datei lesen; bei Fehler (Datei fehlt) als "auth" behandeln.
        let raw = (try? String(contentsOf: stateURL, encoding: .utf8)) ?? "auth"
        let s = StripState(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .auth
        if force || s != current {        // nur bei Änderung neu animieren
            current = s
            applyAll()
        }
    }

    // Zustand direkt schreiben (nur für die Test-Einträge im Menü).
    // Der Checker überschreibt das spätestens nach einem Prüfintervall wieder.
    func write(_ s: StripState) {
        // atomically: erst temporär schreiben, dann ersetzen.
        try? s.rawValue.write(to: stateURL, atomically: true, encoding: .utf8)
        readState()
    }

    // Menü hinter dem ● in der Menüleiste.
    func buildMenu() {
        // Eintrag in der Menüleiste mit variabler Breite (● K, ● L, …).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let m = NSMenu()
        // Kleine Hilfsfunktion, um Menüeinträge kompakt anzulegen.
        func add(_ title: String, _ sel: Selector) { m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }

        add("Anmelden bei Microsoft …",            #selector(login))
        add("Managerliste jetzt aktualisieren",    #selector(refreshManagers))
        add("Log öffnen",                          #selector(openLog))
        m.addItem(.separator())
        add("Test: Kunde (grün)",                  #selector(testCustomer))
        add("Test: Line Manager (gelb)",           #selector(testLine))
        add("Test: Management (rot)",              #selector(testMgmt))
        add("Test: Zurücksetzen (blau)",           #selector(testIdle))
        m.addItem(.separator())
        // Beenden = normales Programmende (Exit-Code 0). launchd startet die
        // App dann bewusst NICHT neu – erst wieder beim nächsten Anmelden.
        m.addItem(withTitle: "Balken beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    // Öffnet Login.command -> Terminal mit Device-Code-Anmeldung.
    @objc func login()           { NSWorkspace.shared.open(loginURL) }
    // Legt eine leere Signaldatei an; der Checker sieht sie beim nächsten Durchlauf.
    @objc func refreshManagers() { FileManager.default.createFile(atPath: refreshURL.path, contents: nil) }
    // Öffnet das Log in der Konsole-App.
    @objc func openLog()         { NSWorkspace.shared.open(logURL) }
    @objc func testCustomer()    { write(.customer) }
    @objc func testLine()        { write(.linemanager) }
    @objc func testMgmt()        { write(.management) }
    @objc func testIdle()        { write(.idle) }
}

// -----------------------------------------------------------------------------
// Einstiegspunkt. ".accessory" = kein Dock-Symbol, nur Menüleiste.
// -----------------------------------------------------------------------------
// Die Delegate-Instanz muss global gehalten werden, sonst wird sie freigegeben.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
