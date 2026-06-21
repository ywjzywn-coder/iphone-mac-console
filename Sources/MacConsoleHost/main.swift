import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum StatusBarLogo {
    static func makeImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setStroke()
        NSColor.black.setFill()

        let trackpad = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5, width: 12.2, height: 9.4), xRadius: 2.6, yRadius: 2.6)
        trackpad.lineWidth = 1.4
        trackpad.stroke()

        let phone = NSBezierPath(roundedRect: NSRect(x: 9.6, y: 1.8, width: 6.2, height: 9.8), xRadius: 1.6, yRadius: 1.6)
        phone.lineWidth = 1.4
        phone.stroke()

        let ring = NSBezierPath(ovalIn: NSRect(x: 6.8, y: 8.2, width: 4, height: 4))
        ring.lineWidth = 1.1
        ring.stroke()

        NSBezierPath(ovalIn: NSRect(x: 8.05, y: 9.45, width: 1.5, height: 1.5)).fill()
        NSBezierPath(ovalIn: NSRect(x: 12.0, y: 5.4, width: 1.8, height: 1.8)).fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

final class ServerController: NSObject, @unchecked Sendable {
    private let projectRoot: String
    private var webServer: LocalWebServer?
    private var ownsServer = false
    private(set) var pairCode = "------"
    private(set) var phoneURLs: [String] = []
    var onUpdate: (() -> Void)?

    init(projectRoot: String) {
        self.projectRoot = projectRoot
        super.init()
    }

    var primaryURL: String? {
        phoneURLs.first { $0.contains("192.") } ?? phoneURLs.first
    }

    func start(forceRestart: Bool = false) {
        debugLog("server start requested forceRestart=\(forceRestart)")

        stop()
        clearStaleServerProcesses()

        let webServer = LocalWebServer(projectRoot: projectRoot)
        webServer.onLog = { [weak self] message in
            self?.debugLog(message)
        }
        webServer.onReady = { [weak self] pairCode, phoneURLs in
            guard let self else { return }
            self.pairCode = pairCode
            self.phoneURLs = phoneURLs
            self.ownsServer = true
            self.writeStatus(running: true)
            self.onUpdate?()
        }
        webServer.onStopped = { [weak self] in
            guard let self else { return }
            self.ownsServer = false
            self.writeStatus(running: false)
            self.onUpdate?()
        }

        do {
            try webServer.start()
            debugLog("Swift web server start issued")
            self.webServer = webServer
        } catch {
            pairCode = "启动失败"
            debugLog("Swift web server failed to start: \(error)")
            writeStatus(running: false)
        }
        onUpdate?()
    }

    private func clearStaleServerProcesses() {
        runQuiet("/usr/bin/pkill", ["-f", "\(projectRoot)/server.js"])

        let output = runCaptured("/usr/sbin/lsof", ["-ti", "tcp:8787"])
        let pids = output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 != getpid() }

        for pid in pids {
            debugLog("killing stale listener pid=\(pid) on tcp:8787")
            kill(pid, SIGTERM)
        }

        if !pids.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
    }

    private func runQuiet(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private func runCaptured(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    func stop() {
        let shouldWriteStopped = ownsServer
        webServer?.stop()
        webServer = nil
        ownsServer = false
        phoneURLs = []
        pairCode = "------"
        if shouldWriteStopped {
            writeStatus(running: false)
        }
        onUpdate?()
    }

    func restart() {
        start(forceRestart: true)
    }

    private func writeStatus(running: Bool) {
        let runtimeDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "running": running,
            "pairCode": pairCode,
            "phoneURLs": phoneURLs,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: runtimeDir.appendingPathComponent("status.json"))
    }

    func debugLog(_ message: String) {
        let runtimeDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = runtimeDir.appendingPathComponent("app-debug.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu = NSMenu()
    private var server: ServerController!
    private var keepAliveTimer: Timer?
    private let projectRoot: String

    override init() {
        let bundleRoot = Bundle.main.object(forInfoDictionaryKey: "MCProjectRoot") as? String
        self.projectRoot = bundleRoot ?? FileManager.default.currentDirectoryPath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtimeDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let bootLine = "\(ISO8601DateFormatter().string(from: Date())) app did finish launching root=\(projectRoot)\n"
        try? bootLine.write(to: runtimeDir.appendingPathComponent("app-debug.log"), atomically: true, encoding: .utf8)

        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Mac Console keeps the local phone-control server available.")
        NSApp.setActivationPolicy(.accessory)
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusBarLogo.makeImage()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Mac Console"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showStatusMenu)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        server = ServerController(projectRoot: projectRoot)
        server.onUpdate = { [weak self] in
            self?.rebuildMenu()
        }
        requestInputPermissionIfNeeded()
        server.start()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.debugLog("app will terminate")
        keepAliveTimer?.invalidate()
        server.stop()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Mac Console", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let pair = NSMenuItem(title: "配对码：\(server.pairCode)", action: #selector(copyPairCode), keyEquivalent: "")
        pair.target = self
        menu.addItem(pair)

        if let url = server.primaryURL {
            let open = NSMenuItem(title: "打开手机页面", action: #selector(openPhoneURL), keyEquivalent: "o")
            open.target = self
            menu.addItem(open)

            let copy = NSMenuItem(title: "复制手机地址：\(url)", action: #selector(copyPhoneURL), keyEquivalent: "c")
            copy.target = self
            menu.addItem(copy)
        } else {
            let waiting = NSMenuItem(title: "等待服务地址...", action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            menu.addItem(waiting)
        }

        menu.addItem(.separator())

        let restart = NSMenuItem(title: "重启服务", action: #selector(restartServer), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        let accessibility = NSMenuItem(title: "打开输入与辅助功能权限", action: #selector(openAccessibility), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)

        let login = NSMenuItem(title: "安装开机启动", action: #selector(installLaunchAgent), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        let removeLogin = NSMenuItem(title: "移除开机启动", action: #selector(removeLaunchAgent), keyEquivalent: "")
        removeLogin.target = self
        menu.addItem(removeLogin)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusMenu = menu
    }

    @objc private func showStatusMenu() {
        rebuildMenu()
        guard let button = statusItem.button else { return }
        statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func copyPairCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.pairCode, forType: .string)
    }

    @objc private func copyPhoneURL() {
        guard let url = server.primaryURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func openPhoneURL() {
        guard let url = server.primaryURL, let nsURL = URL(string: url) else { return }
        NSWorkspace.shared.open(nsURL)
    }

    @objc private func restartServer() {
        server.restart()
    }

    @objc private func openAccessibility() {
        requestInputPermissionIfNeeded(prompt: true)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestInputPermissionIfNeeded(prompt: Bool = false) {
        let granted = CGPreflightPostEventAccess()
        server?.debugLog("post event access preflight granted=\(granted)")
        if !granted || prompt {
            let requested = CGRequestPostEventAccess()
            server?.debugLog("post event access request result=\(requested)")
        }
    }

    @objc private func installLaunchAgent() {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = launchAgents.appendingPathComponent("local.mac-console.host.plist")
        let executablePath = Bundle.main.executablePath ?? "\(Bundle.main.bundlePath)/Contents/MacOS/MacConsoleHost"

        try? FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>local.mac-console.host</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(executablePath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
        </dict>
        </plist>
        """
        try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    @objc private func removeLaunchAgent() {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.mac-console.host.plist")
        try? FileManager.default.removeItem(at: plistURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
private let strongDelegate = AppDelegate()
app.delegate = strongDelegate
app.run()
