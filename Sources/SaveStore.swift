import Foundation

/// A local safety copy for the game's own sealed character strings; the wrapper never edits them.
final class SaveStore {
    static let shared = SaveStore()
    private let queue = DispatchQueue(label: "com.azerothsurvivors.app.saves")
    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalSaveBackup.json")
    func initialJSON() -> String {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let json = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: json, encoding: .utf8) ?? "{}"
    }
    func save(_ values: [String: String]) {
        let clean = values.filter { $0.key == "rogue.characters" || $0.key.hasPrefix("rogue.characters.backup.") }
        guard !clean.isEmpty, let data = try? JSONSerialization.data(withJSONObject: clean), data.count <= 16 * 1024 * 1024 else { return }
        queue.async { try? data.write(to: self.file, options: .atomic) }
    }
}
