import Foundation
import Network

/// A loopback-only static resource server with a stable origin for WKWebView storage.
final class LocalServer {
    let store = ResourceStore()
    private let queue = DispatchQueue(label: "com.azerothsurvivors.app.http", qos: .userInitiated)
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    var origin: String { "http://127.0.0.1:\(port)" }

    func start(completion: @escaping (Bool) -> Void) {
        let saved = UInt16(clamping: UserDefaults.standard.integer(forKey: "serverPort"))
        let candidates = ([saved] + [49761, 49762, 49763, 49764]).filter { $0 != 0 }
        var distinct = [UInt16]()
        for candidate in candidates where !distinct.contains(candidate) { distinct.append(candidate) }
        listen(candidates: distinct, completion: completion)
    }

    private func listen(candidates: [UInt16], completion: @escaping (Bool) -> Void) {
        guard let selected = candidates.first, let endpoint = NWEndpoint.Port(rawValue: selected) else {
            DispatchQueue.main.async { completion(false) }; return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpoint)
            // The port is already specified by requiredLocalEndpoint; passing it twice is rejected by Network.framework.
            let server = try NWListener(using: parameters)
            listener = server
            var completed = false
            server.stateUpdateHandler = { [weak self, weak server] state in
                guard let self = self, !completed else { return }
                switch state {
                case .ready:
                    completed = true; self.port = selected
                    UserDefaults.standard.set(Int(selected), forKey: "serverPort")
                    DispatchQueue.main.async { completion(true) }
                case .failed:
                    completed = true; server?.cancel()
                    self.listen(candidates: Array(candidates.dropFirst()), completion: completion)
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                guard let self = self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.read(connection, buffer: Data())
            }
            server.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { [weak self, weak server] in
                guard !completed else { return }
                completed = true; server?.cancel()
                self?.listen(candidates: Array(candidates.dropFirst()), completion: completion)
            }
        } catch { listen(candidates: Array(candidates.dropFirst()), completion: completion) }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, done, error in
            guard let self = self else { connection.cancel(); return }
            var buffer = buffer
            if let bytes = bytes { buffer.append(bytes) }
            guard buffer.count <= 4 * 1024 * 1024 else { connection.cancel(); return }
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
                if done || error != nil { connection.cancel() } else { self.read(connection, buffer: buffer) }; return
            }
            let lines = header.components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ")
            guard request.count == 3 else { connection.cancel(); return }
            var headers = [String: String]()
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard (0...4 * 1024 * 1024).contains(length) else { connection.cancel(); return }
            let body = Data(buffer[separator.upperBound...])
            if body.count < length {
                if done || error != nil { connection.cancel() } else { self.read(connection, buffer: buffer) }
                return
            }
            self.route(connection, method: String(request[0]), target: String(request[1]), headers: headers, body: Data(body.prefix(length)))
        }
    }

    private func route(_ connection: NWConnection, method: String, target: String, headers: [String: String], body: Data) {
        guard target.hasPrefix("/"), let parsed = URLComponents(string: origin + target),
              parsed.path.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }) else {
            respond(connection, status: 400, headers: [:], body: Data()); return
        }
        let path = parsed.path == "/" ? "index.html" : String(parsed.path.dropFirst())
        var upstream: URL?
        let remote = path.hasPrefix("data/")
        guard !path.hasPrefix("download/"), !path.hasPrefix("__") else {
            respond(connection, status: 404, headers: [:], body: Data()); return
        }
        upstream = URL(string: ResourceStore.site + target)
        let mime = mimeType(path)
        if method == "GET" || method == "HEAD", let data = store.data(path: path, upstream: upstream) {
            serve(connection, method: method, path: path, mime: mime, data: patch(data, path: path), range: headers["range"])
            return
        }
        guard let url = upstream else { respond(connection, status: 400, headers: [:], body: Data()); return }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body.isEmpty ? nil : body
        request.setValue(ResourceStore.userAgent, forHTTPHeaderField: "User-Agent")
        for name in ["content-type", "accept", "accept-language", "user-agent", "cache-control", "range"] {
            if let value = headers[name] { request.setValue(value, forHTTPHeaderField: name) }
        }
        let task = store.fetch(request, cacheAsset: remote && headers["range"] == nil) { [weak self] data, response, error in
            guard let self = self else { connection.cancel(); return }
            guard error == nil, let response = response else {
                self.respond(connection, status: 502, headers: ["Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store"], body: Data("资源暂时无法下载，请检查网络后重试。".utf8)); return
            }
            var output = ["Content-Type": response.value(forHTTPHeaderField: "Content-Type") ?? mime,
                          "Cache-Control": path.hasPrefix("data/") && (200..<300).contains(response.statusCode) ? "public, max-age=31536000, immutable" : "no-store", "Access-Control-Allow-Origin": "*"]
            for name in ["Content-Range", "Accept-Ranges", "Set-Cookie"] {
                if let value = response.value(forHTTPHeaderField: name) { output[name] = value }
            }
            let bytes = self.patch(data ?? Data(), path: path)
            self.respond(connection, status: response.statusCode, headers: output, body: method == "HEAD" ? Data() : bytes,
                         length: method == "HEAD" ? response.expectedContentLength : nil)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: task.cancel()
            default: break
            }
        }
    }

    private func patch(_ data: Data, path: String) -> Data { data }

    private func serve(_ connection: NWConnection, method: String, path: String, mime: String, data: Data, range: String?) {
        var status = 200
        var result = data
        var headers = ["Content-Type": mime, "Accept-Ranges": "bytes", "Cache-Control": path.hasPrefix("data/") ? "public, max-age=31536000, immutable" : "no-cache", "Access-Control-Allow-Origin": "*"]
        if let range = range, range.hasPrefix("bytes="), !range.contains(",") {
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2 {
                let start = parts[0].isEmpty ? max(0, data.count - (Int(parts[1]) ?? 0)) : (Int(parts[0]) ?? -1)
                let end = parts[0].isEmpty || parts[1].isEmpty ? data.count - 1 : min(Int(parts[1]) ?? -1, data.count - 1)
                if start >= 0, start < data.count, end >= start {
                    result = data.subdata(in: start..<(end + 1)); status = 206
                    headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
                } else {
                    respond(connection, status: 416, headers: ["Content-Range": "bytes */\(data.count)"], body: Data()); return
                }
            }
        }
        respond(connection, status: status, headers: headers, body: method == "HEAD" ? Data() : result, length: Int64(result.count))
    }

    private func respond(_ connection: NWConnection, status: Int, headers: [String: String], body: Data, length: Int64? = nil) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(max(0, length ?? Int64(body.count)))\r\n"
        for (name, value) in headers where !value.contains("\r") && !value.contains("\n") { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { connection.cancel() } else { self?.send(connection, data: body, offset: 0) }
        })
    }

    private func send(_ connection: NWConnection, data: Data, offset: Int) {
        guard offset < data.count else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() }); return
        }
        let end = min(offset + 65536, data.count)
        connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            if error != nil { connection.cancel() } else { self?.send(connection, data: data, offset: end) }
        })
    }

    private func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "wasm": return "application/wasm"
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        case "ogg": return "audio/ogg"
        case "mp3": return "audio/mpeg"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
