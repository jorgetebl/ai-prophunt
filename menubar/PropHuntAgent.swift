import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var serverProcess: Process?
    var serverRunning = false
    let port = 3456
    let projectDir: String = {
        // 1. Read from ~/.prophunt/install_dir (set by installer)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installDirFile = home + "/.prophunt/install_dir"
        if let saved = try? String(contentsOfFile: installDirFile, encoding: .utf8) {
            let dir = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.fileExists(atPath: dir + "/run.sh") {
                return dir
            }
        }
        // 2. Check relative to app bundle (dev mode: menubar/ inside project)
        let bundle = Bundle.main.bundlePath
        let menubarDir = (bundle as NSString).deletingLastPathComponent
        let projectDir = (menubarDir as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: projectDir + "/run.sh") {
            return projectDir
        }
        // 3. Common install locations
        for candidate in [home + "/ai-prophunt", home + "/Documents/ai-prophunt"] {
            if FileManager.default.fileExists(atPath: candidate + "/run.sh") {
                return candidate
            }
        }
        // 4. Env var or cwd
        return (ProcessInfo.processInfo.environment["PROPHUNT_DIR"] ?? FileManager.default.currentDirectoryPath)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateIcon(running: false)
        buildMenu()
        startServer()
    }

    func updateIcon(running: Bool) {
        serverRunning = running
        if let button = statusItem.button {
            button.title = running ? "🏠" : "🏚"
            button.toolTip = running ? "PropHunt — Activo" : "PropHunt — Parado"
        }
        buildMenu()
    }

    func buildMenu() {
        let menu = NSMenu()

        let statusText = serverRunning ? "✅ Servidor activo (puerto \(port))" : "⏹ Servidor parado"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        if serverRunning {
            menu.addItem(NSMenuItem(title: "Abrir Dashboard", action: #selector(openDashboard), keyEquivalent: "d"))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Parar servidor", action: #selector(stopServer), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Arrancar servidor", action: #selector(startServer), keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Ejecutar test", action: #selector(runTest), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Health check", action: #selector(runHealthCheck), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ver logs de hoy", action: #selector(openLogs), keyEquivalent: "l"))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q"))

        self.statusItem.menu = menu
    }

    @objc func openDashboard() {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
    }

    @objc func startServer() {
        if serverRunning { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "src/server.js", "--dashboard"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        process.environment = ProcessInfo.processInfo.environment

        // Redirect output to log
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let logPath = "\(projectDir)/data/logs/\(dateFormatter.string(from: Date())).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)
        logHandle?.seekToEndOfFile()
        process.standardOutput = logHandle
        process.standardError = logHandle

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateIcon(running: false)
            }
        }

        do {
            try process.run()
            serverProcess = process
            // Wait a moment then check if it's actually running
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                if process.isRunning {
                    self?.updateIcon(running: true)
                    self?.openDashboard()
                } else {
                    self?.updateIcon(running: false)
                }
            }
        } catch {
            updateIcon(running: false)
        }
    }

    @objc func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        updateIcon(running: false)
    }

    @objc func runTest() {
        let script = "cd '\(projectDir)' && ./run.sh test; echo ''; echo 'Pulsa Enter para cerrar'; read"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Terminal\" to do script \"\(script)\""]
        try? process.run()
    }

    @objc func runHealthCheck() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["\(projectDir)/scripts/healthcheck.sh"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectDir)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "Sin resultado"
            showAlert(title: "Health Check", message: output)
        } catch {
            showAlert(title: "Error", message: "No se pudo ejecutar healthcheck")
        }
    }

    @objc func openLogs() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let logPath = "\(projectDir)/data/logs/\(dateFormatter.string(from: Date())).log"
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func quit() {
        stopServer()
        NSApplication.shared.terminate(nil)
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// --- Main ---
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon, menubar only
let delegate = AppDelegate()
app.delegate = delegate
app.run()
