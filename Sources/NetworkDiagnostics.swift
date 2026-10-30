import Foundation
import Network

/// Local-only connectivity and boot evidence; no save contents, URL queries or request bodies.
final class NetworkDiagnostics {
    static let shared = NetworkDiagnostics()
    private let queue = DispatchQueue(label: "com.azerothsurvivors.app.diagnostics")
    private var lines = [String]()
    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Diagnostics.log")
    func record(_ text: String) {
        queue.async {
            self.lines.append("\(ISO8601DateFormatter().string(from: Date())) \(text.prefix(700))")
            self.lines = Array(self.lines.suffix(120))
            try? self.lines.joined(separator: "\n").write(to: self.file, atomically: true, encoding: .utf8)
            print("[Azeroth] \(text.prefix(700))")
        }
    }
    func request(_ url: URL?, status: Int?, error: Error?) {
        let address = url.map { "\($0.host ?? "?")\($0.path)" } ?? "unknown"
        if let error = error as NSError? { record("NETWORK \(address) \(error.domain):\(error.code)") }
        else { record("NETWORK \(address) HTTP=\(status ?? 0)") }
    }
}
