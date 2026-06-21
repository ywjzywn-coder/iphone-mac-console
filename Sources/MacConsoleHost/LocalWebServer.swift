import CryptoKit
import Foundation
import Network

final class MacControlHelper: @unchecked Sendable {
    private let projectRoot: String
    private var process: Process?
    private var input: Pipe?

    init(projectRoot: String) {
        self.projectRoot = projectRoot
    }

    func send(_ payload: [String: Any]) {
        let process = start()
        guard let input, let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        if !process.isRunning {
            self.process = nil
            self.input = nil
            send(payload)
            return
        }
        input.fileHandleForWriting.write((line + "\n").data(using: .utf8)!)
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        input = nil
    }

    private func start() -> Process {
        if let process, process.isRunning {
            return process
        }

        let helperURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("bin")
            .appendingPathComponent("mac-control")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helperURL
        process.arguments = ["serve"]
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                NSLog("mac-control: \(text)")
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.process = nil
            self?.input = nil
        }
        try? process.run()
        self.process = process
        self.input = input
        return process
    }
}

final class LocalWebServer: @unchecked Sendable {
    private let projectRoot: String
    private let publicDir: URL
    private let port: UInt16
    private let pairCode = String(Int.random(in: 100000...999999))
    private let sessionToken: String
    private let trustedDevices: TrustedDeviceStore
    private let input = MacInputController()
    private var listener: NWListener?
    private var statusTimer: Timer?

    var onReady: ((String, [String]) -> Void)?
    var onLog: ((String) -> Void)?
    var onStopped: (() -> Void)?

    init(projectRoot: String, port: UInt16 = 8787) {
        self.projectRoot = projectRoot
        self.publicDir = URL(fileURLWithPath: projectRoot).appendingPathComponent("public", isDirectory: true)
        self.port = port
        self.sessionToken = loadOrCreateSessionToken(projectRoot: projectRoot)
        self.trustedDevices = TrustedDeviceStore(projectRoot: projectRoot)
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log("Swift web server listening on \(self.port)")
                self.publishStatus()
                DispatchQueue.main.async {
                    self.statusTimer?.invalidate()
                    self.statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                        self?.publishStatus()
                    }
                }
            case .failed(let error):
                self.log("Swift web server failed: \(error)")
                self.onStopped?()
            case .cancelled:
                self.onStopped?()
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        readHTTP(on: connection, data: Data())
    }

    private func readHTTP(on connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var data = data
            if let chunk {
                data.append(chunk)
            }
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
                self.readHTTP(on: connection, data: data)
                return
            }
            let headerData = data[..<headerEnd.lowerBound]
            let headerText = String(data: headerData, encoding: .utf8) ?? ""
            let headers = parseHeaders(headerText.components(separatedBy: "\r\n").dropFirst())
            let contentLength = contentLength(from: headerText)
            let bodyStart = headerEnd.upperBound
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                guard let chunkEnd = data.range(of: Data("\r\n0\r\n\r\n".utf8), in: bodyStart..<data.endIndex) else {
                    self.readHTTP(on: connection, data: data)
                    return
                }
                let body = decodeChunkedBody(Data(data[bodyStart..<chunkEnd.upperBound]))
                self.route(headerText: headerText, body: body, connection: connection)
                return
            }
            if data.count - bodyStart < contentLength {
                self.readHTTP(on: connection, data: data)
                return
            }
            let body = Data(data[bodyStart..<(bodyStart + contentLength)])
            self.route(headerText: headerText, body: body, connection: connection)
        }
    }

    private func route(headerText: String, body: Data, connection: NWConnection) {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendText("Bad request", status: 400, connection: connection)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendText("Bad request", status: 400, connection: connection)
            return
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let headers = parseHeaders(lines.dropFirst())

        if path == "/ws" {
            guard let token = queryValue("token", in: rawPath), token == sessionToken,
                  let key = headers["sec-websocket-key"] else {
                connection.cancel()
                return
            }
            acceptWebSocket(key: key, connection: connection)
            return
        }

        if method == "POST", path == "/api/pair" {
            let object = jsonObject(from: body)
            if object["code"] as? String == pairCode {
                sendJSON(["ok": true, "token": sessionToken, "rememberToken": trustedDevices.issue()], connection: connection)
            } else {
                sendJSON(["ok": false], status: 403, connection: connection)
            }
            return
        }

        if method == "POST", path == "/api/resume" {
            let object = jsonObject(from: body)
            if let rememberToken = object["rememberToken"] as? String,
               trustedDevices.contains(rememberToken) {
                sendJSON(["ok": true, "token": sessionToken], connection: connection)
            } else {
                sendJSON(["ok": false], status: 401, connection: connection)
            }
            return
        }

        if method == "POST", path == "/api/action" {
            guard headers["authorization"] == "Bearer \(sessionToken)" else {
                sendJSON(["ok": false], status: 401, connection: connection)
                return
            }
            if handleAction(jsonObject(from: body)) {
                sendJSON(["ok": true], connection: connection)
            } else {
                sendJSON(["ok": false, "reason": "input-permission-missing"], status: 403, connection: connection)
            }
            return
        }

        if method == "GET", path == "/api/session" {
            let ok = headers["authorization"] == "Bearer \(sessionToken)"
            sendJSON(["ok": ok], status: ok ? 200 : 401, connection: connection)
            return
        }

        serveStatic(path: path, connection: connection)
    }

    private func handleAction(_ payload: [String: Any]) -> Bool {
        input.handle(payload)
    }

    private func acceptWebSocket(key: String, connection: NWConnection) {
        let accept = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let digest = Insecure.SHA1.hash(data: accept)
        let responseKey = Data(digest).base64EncodedString()
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(responseKey)"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.readWebSocket(on: connection, buffer: Data())
        })
    }

    private func readWebSocket(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            let decoded = self.decodeWebSocket(buffer)
            for message in decoded.messages {
                if let data = message.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    _ = self.handleAction(object)
                }
            }
            self.readWebSocket(on: connection, buffer: decoded.remainder)
        }
    }

    private func decodeWebSocket(_ data: Data) -> (messages: [String], remainder: Data) {
        var messages: [String] = []
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 2 <= bytes.count {
            let first = bytes[offset]
            let second = bytes[offset + 1]
            offset += 2
            let opcode = first & 0x0f
            var length = Int(second & 0x7f)
            if opcode == 8 { break }
            if length == 126 {
                guard offset + 2 <= bytes.count else { offset -= 2; break }
                length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
            } else if length == 127 {
                guard offset + 8 <= bytes.count else { offset -= 2; break }
                length = bytes[offset..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
                offset += 8
            }
            let masked = (second & 0x80) != 0
            var mask: [UInt8] = []
            if masked {
                guard offset + 4 <= bytes.count else { offset -= 2; break }
                mask = Array(bytes[offset..<(offset + 4)])
                offset += 4
            }
            guard offset + length <= bytes.count else { break }
            var payload = Array(bytes[offset..<(offset + length)])
            offset += length
            if opcode == 1 {
                if masked {
                    for index in payload.indices {
                        payload[index] ^= mask[index % 4]
                    }
                }
                messages.append(String(decoding: payload, as: UTF8.self))
            }
        }
        return (messages, Data(bytes.dropFirst(offset)))
    }

    private func serveStatic(path: String, connection: NWConnection) {
        var requestPath = path.removingPercentEncoding ?? path
        if requestPath == "/" { requestPath = "/index.html" }
        let base = publicDir.standardizedFileURL
        let fileURL = publicDir.appendingPathComponent(String(requestPath.dropFirst())).standardizedFileURL
        guard fileURL.path.hasPrefix(base.path),
              let data = try? Data(contentsOf: fileURL),
              !isDirectory(fileURL) else {
            sendText("Not found", status: 404, connection: connection)
            return
        }
        send(data: data, status: 200, contentType: contentType(fileURL.path), connection: connection)
    }

    private func sendJSON(_ object: [String: Any], status: Int = 200, connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(data: data, status: status, contentType: "application/json; charset=utf-8", connection: connection)
    }

    private func sendText(_ text: String, status: Int, connection: NWConnection) {
        send(data: Data(text.utf8), status: status, contentType: "text/plain; charset=utf-8", connection: connection)
    }

    private func send(data: Data, status: Int, contentType: String, connection: NWConnection) {
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : status == 403 ? "Forbidden" : status == 404 ? "Not Found" : "Error"
        var response = Data([
            "HTTP/1.1 \(status) \(reason)",
            "content-type: \(contentType)",
            "content-length: \(data.count)",
            "cache-control: no-store",
            "connection: close"
        ].joined(separator: "\r\n").appending("\r\n\r\n").utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        })
    }

    private func publishStatus() {
        onReady?(pairCode, phoneURLs())
    }

    private func phoneURLs() -> [String] {
        localIPv4Addresses().map { "http://\($0):\(port)" }
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}

private func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
    var headers: [String: String] = [:]
    for line in lines {
        guard let separator = line.firstIndex(of: ":") else { continue }
        let key = line[..<separator].lowercased()
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        headers[key] = value
    }
    return headers
}

private func contentLength(from headerText: String) -> Int {
    parseHeaders(headerText.components(separatedBy: "\r\n").dropFirst())["content-length"].flatMap(Int.init) ?? 0
}

private func jsonObject(from data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func decodeChunkedBody(_ data: Data) -> Data {
    var output = Data()
    var offset = data.startIndex
    while offset < data.endIndex {
        guard let lineEnd = data.range(of: Data("\r\n".utf8), in: offset..<data.endIndex),
              let line = String(data: data[offset..<lineEnd.lowerBound], encoding: .utf8),
              let sizeText = line.split(separator: ";").first,
              let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
            break
        }
        offset = lineEnd.upperBound
        if size == 0 { break }
        let next = offset + size
        guard next <= data.endIndex else { break }
        output.append(data[offset..<next])
        offset = min(next + 2, data.endIndex)
    }
    return output
}

private func number(_ value: Any?) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? String { return Double(value) ?? 0 }
    return 0
}

private final class TrustedDeviceStore: @unchecked Sendable {
    private let url: URL
    private var tokenHashes: Set<String>

    init(projectRoot: String) {
        let runtimeDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        self.url = runtimeDir.appendingPathComponent("trusted-devices.json")
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hashes = object["tokenHashes"] as? [String] {
            self.tokenHashes = Set(hashes)
        } else {
            self.tokenHashes = []
        }
    }

    func issue() -> String {
        let token = randomToken()
        tokenHashes.insert(hash(token))
        save()
        return token
    }

    func contains(_ token: String) -> Bool {
        tokenHashes.contains(hash(token))
    }

    private func save() {
        let payload: [String: Any] = [
            "tokenHashes": Array(Array(tokenHashes).suffix(32)),
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url)
    }
}

private func loadOrCreateSessionToken(projectRoot: String) -> String {
    let runtimeDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".runtime", isDirectory: true)
    try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
    let url = runtimeDir.appendingPathComponent("session-token")
    if let token = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       token.count >= 48 {
        return token
    }
    let token = randomToken()
    try? token.write(to: url, atomically: true, encoding: .utf8)
    return token
}

private func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
    return Data(bytes).map { String(format: "%02x", $0) }.joined()
}

private func hash(_ token: String) -> String {
    let digest = SHA256.hash(data: Data(token.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func queryValue(_ name: String, in rawPath: String) -> String? {
    guard let question = rawPath.firstIndex(of: "?") else { return nil }
    let query = rawPath[rawPath.index(after: question)...]
    for item in query.split(separator: "&") {
        let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
        if pair.first == name {
            return pair.dropFirst().first?.removingPercentEncoding
        }
    }
    return nil
}

private func contentType(_ path: String) -> String {
    if path.hasSuffix(".html") { return "text/html; charset=utf-8" }
    if path.hasSuffix(".css") { return "text/css; charset=utf-8" }
    if path.hasSuffix(".js") { return "application/javascript; charset=utf-8" }
    if path.hasSuffix(".webmanifest") { return "application/manifest+json; charset=utf-8" }
    if path.hasSuffix(".svg") { return "image/svg+xml; charset=utf-8" }
    if path.hasSuffix(".png") { return "image/png" }
    if path.hasSuffix(".json") { return "application/json; charset=utf-8" }
    return "application/octet-stream"
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return isDirectory.boolValue
}

private func localIPv4Addresses() -> [String] {
    var addresses: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addresses }
    defer { freeifaddrs(ifaddr) }
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        defer { pointer = current.pointee.ifa_next }
        let interface = current.pointee
        guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
              (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else {
            continue
        }
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            interface.ifa_addr,
            socklen_t(interface.ifa_addr.pointee.sa_len),
            &hostname,
            socklen_t(hostname.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        if result == 0 {
            let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            addresses.append(String(decoding: bytes, as: UTF8.self))
        }
    }
    return addresses
}
