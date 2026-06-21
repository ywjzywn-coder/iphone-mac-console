import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid

var didRequestPostEventAccess = false
var postEventAccessGranted = false

@discardableResult
func ensurePostEventAccess() -> Bool {
    if postEventAccessGranted {
        return true
    }
    if CGPreflightPostEventAccess() {
        postEventAccessGranted = true
        return true
    }
    if !didRequestPostEventAccess {
        didRequestPostEventAccess = true
        let granted = CGRequestPostEventAccess()
        postEventAccessGranted = granted
        if !granted {
            fputs("Input permission missing: allow Mac Console Host or mac-control in Privacy & Security > Accessibility/Input Monitoring.\n", stderr)
        }
        return granted
    }
    return false
}

final class VirtualMouseHID {
    static let shared = VirtualMouseHID()

    private var device: IOHIDUserDevice?
    private var buttonMask: UInt8 = 0
    private var available = false

    private let reportDescriptor = Data([
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x02,       // Usage (Mouse)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x01,       //   Report ID (1)
        0x09, 0x01,       //   Usage (Pointer)
        0xA1, 0x00,       //   Collection (Physical)
        0x05, 0x09,       //     Usage Page (Button)
        0x19, 0x01,       //     Usage Minimum (1)
        0x29, 0x03,       //     Usage Maximum (3)
        0x15, 0x00,       //     Logical Minimum (0)
        0x25, 0x01,       //     Logical Maximum (1)
        0x95, 0x03,       //     Report Count (3)
        0x75, 0x01,       //     Report Size (1)
        0x81, 0x02,       //     Input (Data, Variable, Absolute)
        0x95, 0x01,       //     Report Count (1)
        0x75, 0x05,       //     Report Size (5)
        0x81, 0x01,       //     Input (Constant)
        0x05, 0x01,       //     Usage Page (Generic Desktop)
        0x09, 0x30,       //     Usage (X)
        0x09, 0x31,       //     Usage (Y)
        0x09, 0x38,       //     Usage (Wheel)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x03,       //     Report Count (3)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
        0xC0,             //   End Collection
        0xC0              // End Collection
    ])

    private init() {
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey: reportDescriptor,
            kIOHIDVendorIDKey: 0x1209,
            kIOHIDProductIDKey: 0xC001,
            kIOHIDVersionNumberKey: 1,
            kIOHIDManufacturerKey: "Mac Console",
            kIOHIDProductKey: "Mac Console Virtual Mouse",
            kIOHIDPrimaryUsagePageKey: 0x01,
            kIOHIDPrimaryUsageKey: 0x02
        ]

        guard let created = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 0) else {
            fputs("Virtual HID mouse unavailable; trying HIDSystem/CGEvent fallback.\n", stderr)
            return
        }

        device = created
        available = true
        sendReport(dx: 0, dy: 0, wheel: 0)
    }

    @discardableResult
    func move(dx: Double, dy: Double) -> Bool {
        guard available else { return false }
        sendChunked(dx: Int(dx.rounded()), dy: Int(dy.rounded()), wheel: 0)
        return true
    }

    @discardableResult
    func drag(dx: Double, dy: Double) -> Bool {
        guard available else { return false }
        buttonMask |= 0x01
        sendChunked(dx: Int(dx.rounded()), dy: Int(dy.rounded()), wheel: 0)
        return true
    }

    @discardableResult
    func mouseDown(button: String = "left") -> Bool {
        guard available else { return false }
        buttonMask |= mask(for: button)
        sendReport(dx: 0, dy: 0, wheel: 0)
        return true
    }

    @discardableResult
    func mouseUp(button: String = "left") -> Bool {
        guard available else { return false }
        buttonMask &= ~mask(for: button)
        sendReport(dx: 0, dy: 0, wheel: 0)
        return true
    }

    @discardableResult
    func click(button: String = "left") -> Bool {
        guard available else { return false }
        let button = mask(for: button)
        buttonMask |= button
        sendReport(dx: 0, dy: 0, wheel: 0)
        buttonMask &= ~button
        sendReport(dx: 0, dy: 0, wheel: 0)
        return true
    }

    @discardableResult
    func scroll(dy: Int32) -> Bool {
        guard available else { return false }
        sendChunked(dx: 0, dy: 0, wheel: Int(dy))
        return true
    }

    private func mask(for button: String) -> UInt8 {
        button == "right" ? 0x02 : 0x01
    }

    private func sendChunked(dx: Int, dy: Int, wheel: Int) {
        var remainingX = dx
        var remainingY = dy
        var remainingWheel = wheel

        repeat {
            let stepX = clampReportValue(remainingX)
            let stepY = clampReportValue(remainingY)
            let stepWheel = clampReportValue(remainingWheel)
            sendReport(dx: Int8(stepX), dy: Int8(stepY), wheel: Int8(stepWheel))
            remainingX -= stepX
            remainingY -= stepY
            remainingWheel -= stepWheel
        } while remainingX != 0 || remainingY != 0 || remainingWheel != 0
    }

    private func clampReportValue(_ value: Int) -> Int {
        min(127, max(-127, value))
    }

    private func sendReport(dx: Int8, dy: Int8, wheel: Int8) {
        guard let device else { return }
        var report: [UInt8] = [
            0x01,
            buttonMask,
            UInt8(bitPattern: dx),
            UInt8(bitPattern: dy),
            UInt8(bitPattern: wheel)
        ]
        let reportLength = report.count
        let result = report.withUnsafeMutableBytes { pointer in
            IOHIDUserDeviceHandleReportWithTimeStamp(device, 0, pointer.bindMemory(to: UInt8.self).baseAddress!, reportLength)
        }
        if result != kIOReturnSuccess {
            available = false
            fputs("Virtual HID report failed (\(result)); trying HIDSystem/CGEvent fallback.\n", stderr)
        }
    }
}

final class HIDSystemPoster {
    static let shared = HIDSystemPoster()

    private var connect: io_connect_t = 0
    private var available = false
    private var leftDown = false
    private var rightDown = false

    private init() {
        guard ProcessInfo.processInfo.environment["MAC_CONSOLE_USE_HIDSYSTEM"] == "1" else {
            return
        }

        if IOHIDCheckAccess(kIOHIDRequestTypePostEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypePostEvent)
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else {
            fputs("HIDSystem service unavailable; falling back to CGEvent.\n", stderr)
            return
        }
        defer { IOObjectRelease(service) }

        var opened: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &opened)
        guard result == kIOReturnSuccess, opened != 0 else {
            fputs("HIDSystem open failed (\(result)); falling back to CGEvent.\n", stderr)
            return
        }

        connect = opened
        available = true
    }

    deinit {
        if connect != 0 {
            IOServiceClose(connect)
        }
    }

    @discardableResult
    func move(dx: Double, dy: Double) -> Bool {
        guard available else { return false }
        let result = postRelativeMouse(eventType: UInt32(NX_MOUSEMOVED), dx: dx, dy: dy)
        if result != kIOReturnSuccess {
            disable(result)
            return false
        }
        return true
    }

    @discardableResult
    func drag(dx: Double, dy: Double) -> Bool {
        guard available else { return false }
        let eventType = rightDown ? UInt32(NX_RMOUSEDRAGGED) : UInt32(NX_LMOUSEDRAGGED)
        let result = postRelativeMouse(eventType: eventType, dx: dx, dy: dy)
        if result != kIOReturnSuccess {
            disable(result)
            return false
        }
        return true
    }

    @discardableResult
    func mouseDown(button: String = "left") -> Bool {
        guard available else { return false }
        let eventType: UInt32
        let buttonNumber: UInt8
        if button == "right" {
            rightDown = true
            eventType = UInt32(NX_RMOUSEDOWN)
            buttonNumber = 1
        } else {
            leftDown = true
            eventType = UInt32(NX_LMOUSEDOWN)
            buttonNumber = 0
        }
        let result = postButton(eventType: eventType, buttonNumber: buttonNumber, isDown: true)
        if result != kIOReturnSuccess {
            disable(result)
            return false
        }
        return true
    }

    @discardableResult
    func mouseUp(button: String = "left") -> Bool {
        guard available else { return false }
        let eventType: UInt32
        let buttonNumber: UInt8
        if button == "right" {
            rightDown = false
            eventType = UInt32(NX_RMOUSEUP)
            buttonNumber = 1
        } else {
            leftDown = false
            eventType = UInt32(NX_LMOUSEUP)
            buttonNumber = 0
        }
        let result = postButton(eventType: eventType, buttonNumber: buttonNumber, isDown: false)
        if result != kIOReturnSuccess {
            disable(result)
            return false
        }
        return true
    }

    @discardableResult
    func click(button: String = "left") -> Bool {
        guard available else { return false }
        return mouseDown(button: button) && mouseUp(button: button)
    }

    @discardableResult
    func scroll(dy: Int32) -> Bool {
        guard available else { return false }
        var data = NXEventData()
        data.scrollWheel.deltaAxis1 = Int16(max(Int32(Int16.min), min(Int32(Int16.max), dy)))
        data.scrollWheel.fixedDeltaAxis1 = dy << 16
        data.scrollWheel.pointDeltaAxis1 = dy

        let point = currentPoint()
        let location = IOGPoint(x: clampedIOGCoordinate(point.x), y: clampedIOGCoordinate(point.y))
        let result = withUnsafePointer(to: &data) { pointer in
            IOHIDPostEvent(connect, UInt32(NX_SCROLLWHEELMOVED), location, pointer, UInt32(kNXEventDataVersion), 0, 0)
        }
        if result != kIOReturnSuccess {
            disable(result)
            return false
        }
        return true
    }

    private func postRelativeMouse(eventType: UInt32, dx: Double, dy: Double) -> kern_return_t {
        var data = NXEventData()
        data.mouseMove.dx = Int32(dx.rounded())
        data.mouseMove.dy = Int32(dy.rounded())
        let location = IOGPoint(x: clampedIOGCoordinate(dx), y: clampedIOGCoordinate(dy))
        return withUnsafePointer(to: &data) { pointer in
            IOHIDPostEvent(
                connect,
                eventType,
                location,
                pointer,
                UInt32(kNXEventDataVersion),
                currentButtonFlags(),
                UInt32(kIOHIDSetRelativeCursorPosition)
            )
        }
    }

    private func postButton(eventType: UInt32, buttonNumber: UInt8, isDown: Bool) -> kern_return_t {
        var data = NXEventData()
        data.mouse.click = isDown ? 1 : 0
        data.mouse.pressure = isDown ? 255 : 0
        data.mouse.buttonNumber = buttonNumber
        let point = currentPoint()
        let location = IOGPoint(x: clampedIOGCoordinate(point.x), y: clampedIOGCoordinate(point.y))
        return withUnsafePointer(to: &data) { pointer in
            IOHIDPostEvent(
                connect,
                eventType,
                location,
                pointer,
                UInt32(kNXEventDataVersion),
                currentButtonFlags(),
                UInt32(kIOHIDSetCursorPosition)
            )
        }
    }

    private func currentButtonFlags() -> UInt32 {
        var flags: UInt32 = 0
        if leftDown { flags |= UInt32(NX_LMOUSEDOWNMASK) }
        if rightDown { flags |= UInt32(NX_RMOUSEDOWNMASK) }
        return flags
    }

    private func clampedIOGCoordinate(_ value: Double) -> Int16 {
        Int16(max(Double(Int16.min), min(Double(Int16.max), value.rounded())))
    }

    private func disable(_ result: kern_return_t) {
        available = false
        fputs("HIDSystem post failed (\(result)); falling back to CGEvent.\n", stderr)
    }
}

func currentPoint() -> CGPoint {
    return CGEvent(source: nil)?.location ?? CGPoint(x: 0, y: 0)
}

func postMouse(_ type: CGEventType, button: CGMouseButton, at point: CGPoint) {
    _ = ensurePostEventAccess()
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    event?.post(tap: .cghidEventTap)
}

func postButtonDownUp(downType: CGEventType, upType: CGEventType, button: CGMouseButton, at point: CGPoint) {
    postMouse(downType, button: button, at: point)
    usleep(12_000)
    postMouse(upType, button: button, at: point)
}

func moveMouse(dx: Double, dy: Double) {
    if VirtualMouseHID.shared.move(dx: dx, dy: dy) { return }
    if HIDSystemPoster.shared.move(dx: dx, dy: dy) { return }
    _ = ensurePostEventAccess()
    let point = currentPoint()
    let next = CGPoint(x: point.x + dx, y: point.y + dy)
    CGWarpMouseCursorPosition(next)
    postMouse(.mouseMoved, button: .left, at: next)
}

func mouseDown(button: String = "left") {
    let point = currentPoint()
    if button == "right" {
        postMouse(.rightMouseDown, button: .right, at: point)
    } else {
        postMouse(.leftMouseDown, button: .left, at: point)
    }
}

func mouseUp(button: String = "left") {
    let point = currentPoint()
    if button == "right" {
        postMouse(.rightMouseUp, button: .right, at: point)
    } else {
        postMouse(.leftMouseUp, button: .left, at: point)
    }
}

func dragMouse(dx: Double, dy: Double) {
    if VirtualMouseHID.shared.drag(dx: dx, dy: dy) { return }
    if HIDSystemPoster.shared.drag(dx: dx, dy: dy) { return }
    let point = currentPoint()
    let next = CGPoint(x: point.x + dx, y: point.y + dy)
    CGWarpMouseCursorPosition(next)
    postMouse(.leftMouseDragged, button: .left, at: next)
}

func click(button: String) {
    let point = currentPoint()
    if button == "right" {
        postButtonDownUp(downType: .rightMouseDown, upType: .rightMouseUp, button: .right, at: point)
    } else {
        postButtonDownUp(downType: .leftMouseDown, upType: .leftMouseUp, button: .left, at: point)
    }
}

func scroll(dy: Int32) {
    if VirtualMouseHID.shared.scroll(dy: dy) { return }
    if HIDSystemPoster.shared.scroll(dy: dy) { return }
    _ = ensurePostEventAccess()
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
    event?.post(tap: .cghidEventTap)
}

func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
    _ = ensurePostEventAccess()
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)

    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
}

func typeText(_ text: String) {
    _ = ensurePostEventAccess()
    for scalar in text.unicodeScalars {
        let chars = Array(String(scalar).utf16)
        let length = chars.count
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        chars.withUnsafeBufferPointer { buffer in
            down?.keyboardSetUnicodeString(stringLength: length, unicodeString: buffer.baseAddress)
        }
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        chars.withUnsafeBufferPointer { buffer in
            up?.keyboardSetUnicodeString(stringLength: length, unicodeString: buffer.baseAddress)
        }
        up?.post(tap: .cghidEventTap)
    }
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126
]

func shortcut(_ combo: String) {
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    guard let key = parts.last, let code = keyCodes[key] else { return }
    var flags: CGEventFlags = []
    if parts.contains("cmd") || parts.contains("command") { flags.insert(.maskCommand) }
    if parts.contains("shift") { flags.insert(.maskShift) }
    if parts.contains("opt") || parts.contains("option") || parts.contains("alt") { flags.insert(.maskAlternate) }
    if parts.contains("ctrl") || parts.contains("control") { flags.insert(.maskControl) }
    postKey(code: code, flags: flags)
}

func missionControl() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Mission Control"]
    try? process.run()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
        postKey(code: 126, flags: .maskControl)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.18))
}

func handleCommand(_ command: [String: Any]) {
    guard let type = command["type"] as? String else { return }
    switch type {
    case "move":
        moveMouse(dx: command["dx"] as? Double ?? 0, dy: command["dy"] as? Double ?? 0)
    case "mouseDown":
        mouseDown(button: command["button"] as? String ?? "left")
    case "mouseUp":
        mouseUp(button: command["button"] as? String ?? "left")
    case "drag":
        dragMouse(dx: command["dx"] as? Double ?? 0, dy: command["dy"] as? Double ?? 0)
    case "click":
        click(button: command["button"] as? String ?? "left")
    case "scroll":
        scroll(dy: Int32(command["dy"] as? Double ?? 0))
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
    default:
        return
    }
}

func serve() {
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let command = json as? [String: Any] else {
            continue
        }
        handleCommand(command)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { exit(1) }

switch args[1] {
case "serve":
    serve()
case "move":
    moveMouse(dx: Double(args[safe: 2] ?? "0") ?? 0, dy: Double(args[safe: 3] ?? "0") ?? 0)
case "mouseDown":
    mouseDown(button: args[safe: 2] ?? "left")
case "mouseUp":
    mouseUp(button: args[safe: 2] ?? "left")
case "drag":
    dragMouse(dx: Double(args[safe: 2] ?? "0") ?? 0, dy: Double(args[safe: 3] ?? "0") ?? 0)
case "click":
    click(button: args[safe: 2] ?? "left")
case "scroll":
    scroll(dy: Int32(args[safe: 2] ?? "0") ?? 0)
case "text":
    typeText(args[safe: 2] ?? "")
case "key":
    if let key = args[safe: 2]?.lowercased(), let code = keyCodes[key] {
        postKey(code: code)
    }
case "shortcut":
    shortcut(args[safe: 2] ?? "")
case "mission":
    missionControl()
default:
    exit(1)
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
