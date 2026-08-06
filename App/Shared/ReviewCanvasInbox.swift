import Foundation

struct InboxDiagram: Equatable {
    let diagramID: UUID
    let revisionID: UUID
    let title: String
    let source: String
    let createdAt: Date
}

struct ReviewCanvasInbox {
    private static let maximumEnvelopeBytes = 3 * 1_024 * 1_024

    private let fileManager = FileManager.default
    private let overrideDirectoryURL: URL?

    init(directoryURL: URL? = nil) {
        overrideDirectoryURL = directoryURL
    }

    var directoryURL: URL {
        if let overrideDirectoryURL {
            return overrideDirectoryURL
        }

        if let override = ProcessInfo.processInfo.environment["REVIEW_CANVAS_DATA_DIR"],
           override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Review Canvas", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    var pendingCount: Int {
        pendingFiles.count
    }

    func importNext() throws -> InboxDiagram? {
        guard let fileURL = pendingFiles.first else {
            return nil
        }

        guard isValidEnvelopeFile(fileURL) else {
            throw InboxError.invalidEnvelopeFile
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = ReviewCanvasDateCoding.makeDecoder()
        let envelope = try decoder.decode(InboxEnvelope.self, from: data)

        guard envelope.schemaVersion == 1 else {
            throw InboxError.unsupportedSchema(envelope.schemaVersion)
        }

        guard
            envelope.revision.parentRevisionID == nil,
            envelope.revision.sequence == 1,
            envelope.revision.status == "current"
        else {
            throw InboxError.invalidInitialRevision
        }

        let source = envelope.revision.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw InboxError.emptySource
        }

        try archive(fileURL)
        return InboxDiagram(
            diagramID: envelope.diagramID,
            revisionID: envelope.revision.id,
            title: envelope.title,
            source: source,
            createdAt: envelope.createdAt
        )
    }

    private var pendingFiles: [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter(isValidEnvelopeFile)
            .sorted { lhs, rhs in
                let leftDate = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let rightDate = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (leftDate ?? .distantPast) < (rightDate ?? .distantPast)
            }
    }

    private func isValidEnvelopeFile(_ fileURL: URL) -> Bool {
        guard fileURL.pathExtension.lowercased() == "json" else {
            return false
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let prefix = "diagram-"
        guard stem.hasPrefix(prefix), UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil else {
            return false
        }

        guard let values = try? fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]) else {
            return false
        }

        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? Self.maximumEnvelopeBytes + 1) <= Self.maximumEnvelopeBytes
    }

    private func archive(_ fileURL: URL) throws {
        let processedDirectory = directoryURL.appendingPathComponent("Processed", isDirectory: true)
        try fileManager.createDirectory(at: processedDirectory, withIntermediateDirectories: true)

        var destination = processedDirectory.appendingPathComponent(fileURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            destination = processedDirectory.appendingPathComponent(
                "\(fileURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).json"
            )
        }
        try fileManager.moveItem(at: fileURL, to: destination)
    }
}

private struct InboxEnvelope: Decodable {
    let schemaVersion: Int
    let diagramID: UUID
    let title: String
    let createdAt: Date
    let revision: InboxRevision

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case diagramID = "diagramId"
        case title
        case createdAt
        case revision
    }
}

private struct InboxRevision: Decodable {
    let id: UUID
    let parentRevisionID: UUID?
    let sequence: Int
    let status: String
    let source: String

    private enum CodingKeys: String, CodingKey {
        case id
        case parentRevisionID = "parentRevisionId"
        case sequence
        case status
        case source
    }
}

private enum InboxError: LocalizedError {
    case unsupportedSchema(Int)
    case emptySource
    case invalidInitialRevision
    case invalidEnvelopeFile

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "지원하지 않는 Review Canvas inbox 버전입니다: \(version)"
        case .emptySource:
            return "Inbox 다이어그램이 비어 있습니다."
        case .invalidInitialRevision:
            return "Inbox의 첫 revision 형식이 올바르지 않습니다."
        case .invalidEnvelopeFile:
            return "Inbox 파일 형식이 안전하지 않습니다."
        }
    }
}
