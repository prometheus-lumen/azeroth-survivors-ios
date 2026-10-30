import Foundation
import CryptoKit

/// The packaged core is a consistent snapshot. Additional public data is cached per game build.
final class ResourceStore {
    static let site = "https://wow.aethus.pl"
    static let userAgent = "Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Version/26.0 Mobile/15E148 Safari/604.1"
    private let bundled = Bundle.main.bundleURL.appendingPathComponent("www", isDirectory: true)
    private let session: URLSession
    private let cache: URL
    private let writes = DispatchQueue(label: "com.azerothsurvivors.app.cache")
    private var saved = 0

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: configuration)
        let url = Bundle.main.bundleURL.appendingPathComponent("www/bundle-manifest.json")
        let manifest = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let build = manifest?["build"] as? String ?? "bundled"
        cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameData-" + build, isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    func data(path: String, upstream: URL?) -> Data? {
        guard !path.split(separator: "/").contains("..") else { return nil }
        if let data = try? Data(contentsOf: bundled.appendingPathComponent(path), options: .mappedIfSafe) { return data }
        guard let url = upstream else { return nil }
        return try? Data(contentsOf: cacheURL(url), options: .mappedIfSafe)
    }

    private func cacheURL(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent(digest)
    }

    @discardableResult
    func fetch(_ request: URLRequest, cacheAsset: Bool, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> URLSessionDataTask {
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            if error != nil || (http?.statusCode ?? 200) >= 400 {
                NetworkDiagnostics.shared.request(request.url, status: http?.statusCode, error: error)
            }
            if cacheAsset, request.httpMethod == "GET", http?.statusCode == 200,
               let data = data, data.count <= 128 * 1024 * 1024, let url = request.url, let self = self {
                self.writes.async {
                    try? data.write(to: self.cacheURL(url), options: .atomic)
                    self.saved += 1
                    if self.saved % 32 == 0 { self.trimCache() }
                }
            }
            completion(data, http, error)
        }
        task.resume()
        return task
    }

    private func trimCache() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let values = files.compactMap { file -> (URL, Int, Date)? in
            guard let value = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, value.fileSize ?? 0, value.contentModificationDate ?? .distantPast)
        }
        var bytes = values.reduce(0) { $0 + $1.1 }
        for entry in values.sorted(by: { $0.2 < $1.2 }) where bytes > 1024 * 1024 * 1024 {
            try? manager.removeItem(at: entry.0); bytes -= entry.1
        }
    }
}
