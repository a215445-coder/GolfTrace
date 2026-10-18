import Foundation

final class ShotLibrary {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var rootURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("GolfTrace", isDirectory: true)
    }

    private var indexURL: URL {
        rootURL.appendingPathComponent("index.json")
    }

    init() {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func importVideo(from sourceURL: URL) throws -> ShotRecord {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let fileName = "\(id.uuidString).\(ext)"
        let destination = rootURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        return ShotRecord(
            id: id,
            createdAt: Date(),
            videoFileName: fileName,
            trace: ShotTrace(points: [], confidence: 0, videoWidth: 0, videoHeight: 0)
        )
    }

    func videoURL(for shot: ShotRecord) -> URL {
        rootURL.appendingPathComponent(shot.videoFileName)
    }

    func save(_ shot: ShotRecord) throws {
        let url = rootURL.appendingPathComponent("\(shot.id.uuidString).json")
        try encoder.encode(shot).write(to: url, options: .atomic)
        var index = loadIndex().filter { $0.id != shot.id }
        index.insert(shot, at: 0)
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    func loadIndex() -> [ShotRecord] {
        guard let data = try? Data(contentsOf: indexURL),
              let shots = try? decoder.decode([ShotRecord].self, from: data)
        else { return [] }
        return shots
    }

    func loadShot(id: UUID) -> ShotRecord? {
        let url = rootURL.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(ShotRecord.self, from: data)
    }

    func delete(_ shot: ShotRecord) {
        try? fileManager.removeItem(at: rootURL.appendingPathComponent("\(shot.id.uuidString).json"))
        try? fileManager.removeItem(at: videoURL(for: shot))
        let index = loadIndex().filter { $0.id != shot.id }
        try? encoder.encode(index).write(to: indexURL, options: .atomic)
    }
}

extension ShotRecord {
    var videoURL: URL {
        ShotLibrary().videoURL(for: self)
    }
}
