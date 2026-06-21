import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class MacInputController: @unchecked Sendable {
    private enum SnapZone: Equatable {
        case left
        case right
        case top
    }

    private var didRequestPostEventAccess = false
    private var postEventAccessGranted = false
    private var pressedButton: CGMouseButton?
    private var dragSessionStartedAt = Date.distantPast
    private var lastSnapAt = Date.distantPast
    private var lastSnapZone: SnapZone?
    private var hiddenDesktopWindows: [AXUIElement] = []
    private let mouseSource = CGEventSource(stateID: .hidSystemState)

    @discardableResult
    func handle(_ command: [String: Any]) -> Bool {
        guard let type = command["type"] as? String else { return false }
        if type != "notification", !ensurePostEventAccess() { return false }
        switch type {
        case "move":
            moveMouse(dx: number(command["dx"]), dy: number(command["dy"]))
        case "mouseDown":
            mouseDown(button: command["button"] as? String ?? "left")
        case "mouseUp":
            mouseUp(button: command["button"] as? String ?? "left")
        case "drag":
            dragMouse(dx: number(command["dx"]), dy: number(command["dy"]))
        case "click":
            click(button: command["button"] as? String ?? "left")
        case "scroll":
            scroll(dy: Int32(number(command["dy"])))
        case "text":
            typeText(command["value"] as? String ?? "")
        case "key":
            if let key = (command["key"] as? String)?.lowercased(), let code = keyCodes[key] {
                postKey(code: code)
            }
        case "shortcut":
            shortcut(command["combo"] as? String ?? "")
        case "mission":
            missionControl()
        case "notification":
            return notificationCenter()
        case "showDesktop":
            showDesktop()
        case "restoreDesktop":
            restoreDesktop()
        default:
            return false
        }
        return true
    }

    private func currentPoint() -> CGPoint {
        CGEvent(source: nil)?.location ?? CGPoint(x: 0, y: 0)
    }

    @discardableResult
    private func ensurePostEventAccess() -> Bool {
        if postEventAccessGranted { return true }
        if CGPreflightPostEventAccess() {
            postEventAccessGranted = true
            return true
        }
        if !didRequestPostEventAccess {
            didRequestPostEventAccess = true
            postEventAccessGranted = CGRequestPostEventAccess()
        }
        return postEventAccessGranted
    }

    private func postMouse(_ type: CGEventType, button: CGMouseButton, at point: CGPoint, dx: Double = 0, dy: Double = 0) {
        guard ensurePostEventAccess() else { return }
        let event = CGEvent(mouseEventSource: mouseSource, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        if pressedButton == .left || type == .leftMouseDown || type == .leftMouseDragged {
            event?.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        } else if pressedButton == .right || type == .rightMouseDown || type == .rightMouseDragged {
            event?.setIntegerValueField(.mouseEventButtonNumber, value: 1)
        }
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event?.post(tap: .cghidEventTap)
    }

    private func postButtonDownUp(downType: CGEventType, upType: CGEventType, button: CGMouseButton, at point: CGPoint) {
        postMouse(downType, button: button, at: point)
        usleep(16_000)
        postMouse(upType, button: button, at: point)
    }

    private func moveMouse(dx: Double, dy: Double) {
        guard ensurePostEventAccess() else { return }
        let point = currentPoint()
        let next = CGPoint(x: point.x + dx, y: point.y + dy)
        postMouse(.mouseMoved, button: .left, at: next, dx: dx, dy: dy)
        CGWarpMouseCursorPosition(next)
    }

    private func mouseDown(button: String) {
        let point = currentPoint()
        if button == "right" {
            pressedButton = .right
            postMouse(.rightMouseDown, button: .right, at: point)
        } else {
            pressedButton = .left
            dragSessionStartedAt = Date()
            lastSnapZone = nil
            postMouse(.leftMouseDown, button: .left, at: point)
        }
    }

    private func mouseUp(button: String) {
        let point = currentPoint()
        if button == "right" {
            postMouse(.rightMouseUp, button: .right, at: point)
        } else {
            postMouse(.leftMouseUp, button: .left, at: point)
        }
        pressedButton = nil
        dragSessionStartedAt = Date.distantPast
        lastSnapZone = nil
    }

    private func dragMouse(dx: Double, dy: Double) {
        guard ensurePostEventAccess() else { return }
        let point = currentPoint()
        let next = CGPoint(x: point.x + dx, y: point.y + dy)
        if pressedButton == .right {
            postMouse(.rightMouseDragged, button: .right, at: next, dx: dx, dy: dy)
        } else {
            if pressedButton == nil { pressedButton = .left }
            postMouse(.leftMouseDragged, button: .left, at: next, dx: dx, dy: dy)
        }
        CGWarpMouseCursorPosition(next)
        if pressedButton == .left {
            maybeSnapFrontWindow(at: next)
        }
    }

    private func click(button: String) {
        let point = currentPoint()
        if button == "right" {
            postButtonDownUp(downType: .rightMouseDown, upType: .rightMouseUp, button: .right, at: point)
        } else {
            postButtonDownUp(downType: .leftMouseDown, upType: .leftMouseUp, button: .left, at: point)
        }
    }

    private func scroll(dy: Int32) {
        guard ensurePostEventAccess() else { return }
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard ensurePostEventAccess() else { return }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) {
        guard ensurePostEventAccess() else { return }
        for scalar in text.unicodeScalars {
            let chars = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            chars.withUnsafeBufferPointer { buffer in
                down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: buffer.baseAddress)
            }
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            chars.withUnsafeBufferPointer { buffer in
                up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: buffer.baseAddress)
            }
            up?.post(tap: .cghidEventTap)
        }
    }

    private func shortcut(_ combo: String) {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, let code = keyCodes[key] else { return }
        var flags: CGEventFlags = []
        if parts.contains("cmd") || parts.contains("command") { flags.insert(.maskCommand) }
        if parts.contains("shift") { flags.insert(.maskShift) }
        if parts.contains("opt") || parts.contains("option") || parts.contains("alt") { flags.insert(.maskAlternate) }
        if parts.contains("ctrl") || parts.contains("control") { flags.insert(.maskControl) }
        postKey(code: code, flags: flags)
    }

    private func missionControl() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Mission Control"]
        try? process.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.postKey(code: 126, flags: .maskControl)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.18))
    }

    private func notificationCenter() -> Bool {
        let scripts = [
            """
            tell application "System Events"
                tell process "ControlCenter"
                    click (first menu bar item of menu bar 1 whose description is "时钟")
                end tell
            end tell
            """,
            """
            tell application "System Events"
                tell process "ControlCenter"
                    click menu bar item 1 of menu bar 1
                end tell
            end tell
            """
        ]

        for script in scripts {
            if runAppleScript(script) {
                return true
            }
        }
        return false
    }

    private func showDesktop() {
        if minimizeVisibleWindowsForDesktop() {
            return
        }
        postKey(code: 103, flags: .maskSecondaryFn)
    }

    private func restoreDesktop() {
        if restoreWindowsForDesktop() {
            return
        }
        postKey(code: 103, flags: .maskSecondaryFn)
    }

    private func maybeSnapFrontWindow(at point: CGPoint) {
        let now = Date()
        guard now.timeIntervalSince(dragSessionStartedAt) > 0.18 else { return }

        guard let displayID = displayContaining(point),
              let zone = snapZone(for: point, displayID: displayID) else {
            lastSnapZone = nil
            return
        }

        if zone == lastSnapZone, now.timeIntervalSince(lastSnapAt) < 1.2 {
            return
        }

        guard let window = frontmostWindow() else { return }
        let frame = snapFrame(for: zone, displayID: displayID)
        guard setWindow(window, frame: frame) else { return }

        lastSnapZone = zone
        lastSnapAt = now
    }

    private func snapZone(for point: CGPoint, displayID: CGDirectDisplayID) -> SnapZone? {
        let bounds = CGDisplayBounds(displayID)
        let horizontalThreshold: CGFloat = 28
        let topThreshold: CGFloat = 22

        if point.x <= bounds.minX + horizontalThreshold {
            return .left
        }
        if point.x >= bounds.maxX - horizontalThreshold {
            return .right
        }
        if point.y <= bounds.minY + topThreshold {
            return .top
        }
        return nil
    }

    private func snapFrame(for zone: SnapZone, displayID: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        let menuBarAllowance: CGFloat = 24
        let frame = CGRect(
            x: bounds.minX,
            y: bounds.minY + menuBarAllowance,
            width: bounds.width,
            height: max(120, bounds.height - menuBarAllowance)
        )

        switch zone {
        case .left:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:
            return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            return frame
        }
    }

    private func displayContaining(_ point: CGPoint) -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        var result = CGGetDisplaysWithPoint(point, 0, nil, &displayCount)
        guard result == .success, displayCount > 0 else {
            return CGMainDisplayID()
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        result = CGGetDisplaysWithPoint(point, displayCount, &displays, &displayCount)
        guard result == .success else {
            return CGMainDisplayID()
        }
        return displays.first
    }

    private func frontmostWindow() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let window = focusedValue {
            return (window as! AXUIElement)
        }

        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }
        return windows.first
    }

    private func minimizeVisibleWindowsForDesktop() -> Bool {
        let windows = controllableWindows()
        guard !windows.isEmpty else { return false }

        var minimizedWindows: [AXUIElement] = []
        for window in windows where !isWindowMinimized(window) {
            if setWindowMinimized(window, minimized: true) {
                minimizedWindows.append(window)
            }
        }

        guard !minimizedWindows.isEmpty else { return false }
        hiddenDesktopWindows = minimizedWindows
        return true
    }

    private func restoreWindowsForDesktop() -> Bool {
        guard !hiddenDesktopWindows.isEmpty else { return false }

        var restoredAny = false
        for window in hiddenDesktopWindows {
            if setWindowMinimized(window, minimized: false) {
                restoredAny = true
            }
        }

        hiddenDesktopWindows.removeAll()
        return restoredAny
    }

    private func controllableWindows() -> [AXUIElement] {
        guard AXIsProcessTrusted() else { return [] }
        let currentPID = ProcessInfo.processInfo.processIdentifier

        return NSWorkspace.shared.runningApplications.flatMap { app -> [AXUIElement] in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != currentPID else {
                return []
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsValue: AnyObject?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement] else {
                return []
            }
            return windows
        }
    }

    private func isWindowMinimized(_ window: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              let minimized = value as? Bool else {
            return false
        }
        return minimized
    }

    private func setWindowMinimized(_ window: AXUIElement, minimized: Bool) -> Bool {
        let value = (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value) == .success
    }

    private func setWindow(_ window: AXUIElement, frame: CGRect) -> Bool {
        var position = frame.origin
        var size = frame.size

        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return positionResult == .success && sizeResult == .success
    }

    private func runAppleScript(_ source: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126
]

private func number(_ value: Any?) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? String { return Double(value) ?? 0 }
    return 0
}
