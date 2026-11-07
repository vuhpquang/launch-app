// Control/ControlServer.swift
// A Unix-domain socket in the app's support folder (owner-only, 0600) that takes one JSON
// request per connection — {"cmd": "...", "args": {...}} plus a newline — runs it on the
// main thread and answers {"ok": true, "result": ...} or {"ok": false, "error": "..."}.
// The MCP server (`LaunchApp mcp`) is its client.

import Foundation

enum ControlSocket {
    static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LaunchApp/control.sock").path
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }

    /// Reads up to the first newline (or EOF).
    static func readLine(_ fd: Int32, limit: Int = 8 << 20) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while data.count < limit {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 10) {
                data.append(contentsOf: buf[0..<nl])
                return data
            }
            data.append(contentsOf: buf[0..<n])
        }
        return data.isEmpty ? nil : data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    /// Client side: sends one command and returns the decoded reply.
    static func send(_ cmd: String, _ args: [String: Any], timeout: TimeInterval = 20) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("socket() failed") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard var addr = address(path) else { throw ControlError("socket path too long") }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw ControlError("LaunchApp isn't running") }
        var payload = try JSONSerialization.data(withJSONObject: ["cmd": cmd, "args": args])
        payload.append(10)
        writeAll(fd, payload)
        guard let line = readLine(fd),
              let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ControlError("no reply from LaunchApp")
        }
        return reply
    }
}

final class ControlServer {
    typealias Handler = (_ cmd: String, _ args: [String: Any]) throws -> Any
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "launchapp.control", attributes: .concurrent)

    init(handler: @escaping Handler) { self.handler = handler }

    func start() {
        let path = ControlSocket.path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = ControlSocket.address(path) else { return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); Log.error("control socket: bind/listen failed"); return }
        chmod(path, 0o600)
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(ControlSocket.path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 {
                if errno == EINTR { continue }
                return
            }
            // Only our own user may talk to us (the socket is 0600 too).
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(conn, &uid, &gid) != 0 || uid != getuid() { close(conn); continue }
            queue.async { [weak self] in self?.serve(conn) }
        }
    }

    private func serve(_ conn: Int32) {
        defer { close(conn) }
        var reply: [String: Any]
        if let line = ControlSocket.readLine(conn),
           let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           let cmd = req["cmd"] as? String {
            let args = req["args"] as? [String: Any] ?? [:]
            reply = DispatchQueue.main.sync {
                do { return ["ok": true, "result": try self.handler(cmd, args)] }
                catch { return ["ok": false, "error": "\(error)"] }
            }
        } else {
            reply = ["ok": false, "error": "bad request"]
        }
        var data = (try? JSONSerialization.data(withJSONObject: reply, options: [.fragmentsAllowed]))
            ?? Data(#"{"ok":false,"error":"unencodable result"}"#.utf8)
        data.append(10)
        ControlSocket.writeAll(conn, data)
    }
}
