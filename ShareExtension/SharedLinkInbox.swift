import Foundation

enum SharedLinkInbox {
    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.davidlabworks.miaoreader")?
            .appendingPathComponent("SharedLinks", isDirectory: true)
    }

    static func save(_ url: URL) throws {
        guard let directory else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).link"
        try Data(url.absoluteString.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func nextFile() throws -> URL? {
        guard let directory else { return nil }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return files.filter { $0.pathExtension == "link" }.min { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}
