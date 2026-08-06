import Foundation
import ReviewCanvasCore

struct MCPReviewOutbox {
    private let fileManager = FileManager.default
    private let overrideDirectoryURL: URL?

    init(directoryURL: URL? = nil) {
        overrideDirectoryURL = directoryURL
    }

    var directoryURL: URL {
        if let overrideDirectoryURL {
            return overrideDirectoryURL
        }

        let inbox = ReviewCanvasInbox().directoryURL
        return inbox
            .appendingPathComponent("ReviewOutbox", isDirectory: true)
            .appendingPathComponent("Pending", isDirectory: true)
    }

    @discardableResult
    func export(document: DiagramDocument, at exportedAt: Date = Date()) throws -> URL? {
        guard let revision = document.currentRevision else {
            return nil
        }
        let marks = document.reviewMarks.filter { $0.revisionID == revision.id }
        guard !marks.isEmpty else {
            return nil
        }

        let exportID = UUID()
        let envelope = MCPReviewExportEnvelope(
            exportID: exportID,
            exportedAt: exportedAt,
            document: document,
            revision: revision,
            marks: marks
        )
        let encoder = ReviewCanvasDateCoding.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directoryURL.appendingPathComponent("review-\(exportID.uuidString).json")
        let temporary = directoryURL.appendingPathComponent(".review-\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

private struct MCPReviewExportEnvelope: Encodable {
    let schemaVersion = 1
    let exportID: UUID
    let exportedAt: Date
    let diagram: Diagram
    let revision: Revision
    let marks: [Mark]

    init(
        exportID: UUID,
        exportedAt: Date,
        document: DiagramDocument,
        revision: DiagramRevision,
        marks: [ReviewMark]
    ) {
        self.exportID = exportID
        self.exportedAt = exportedAt
        diagram = Diagram(document)
        self.revision = Revision(revision)
        self.marks = marks.map { Mark($0, diagramID: document.id) }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case exportID = "exportId"
        case exportedAt
        case diagram
        case revision
        case marks
    }

    struct Diagram: Encodable {
        let id: UUID
        let title: String
        let currentRevisionID: UUID
        let createdAt: Date
        let updatedAt: Date

        init(_ document: DiagramDocument) {
            id = document.id
            title = document.title
            currentRevisionID = document.currentRevisionID
            createdAt = document.createdAt
            updatedAt = document.updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case currentRevisionID = "currentRevisionId"
            case createdAt
            case updatedAt
        }
    }

    struct Revision: Encodable {
        let id: UUID
        let parentRevisionID: UUID?
        let sequence: Int
        let status: DiagramRevisionStatus
        let source: String
        let createdAt: Date

        init(_ revision: DiagramRevision) {
            id = revision.id
            parentRevisionID = revision.parentRevisionID
            sequence = revision.sequence
            status = revision.status
            source = revision.source
            createdAt = revision.createdAt
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case parentRevisionID = "parentRevisionId"
            case sequence
            case status
            case source
            case createdAt
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            if let parentRevisionID {
                try container.encode(parentRevisionID, forKey: .parentRevisionID)
            } else {
                try container.encodeNil(forKey: .parentRevisionID)
            }
            try container.encode(sequence, forKey: .sequence)
            try container.encode(status, forKey: .status)
            try container.encode(source, forKey: .source)
            try container.encode(createdAt, forKey: .createdAt)
        }
    }

    struct Mark: Encodable {
        let id: UUID
        let diagramID: UUID
        let revisionID: UUID
        let type: ReviewMarkType
        let symbol: String
        let body: String
        let status: ReviewStatus
        let anchor: DiagramAnchor
        let createdAt: Date
        let updatedAt: Date
        let resolvedAt: Date?

        init(_ mark: ReviewMark, diagramID: UUID) {
            id = mark.id
            self.diagramID = diagramID
            revisionID = mark.revisionID
            type = mark.type
            symbol = mark.type.displaySymbol
            body = mark.body
            status = mark.status
            anchor = mark.anchor
            createdAt = mark.createdAt
            updatedAt = mark.updatedAt
            resolvedAt = mark.resolvedAt
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case diagramID = "diagramId"
            case revisionID = "revisionId"
            case type
            case symbol
            case body
            case status
            case anchor
            case createdAt
            case updatedAt
            case resolvedAt
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(diagramID, forKey: .diagramID)
            try container.encode(revisionID, forKey: .revisionID)
            try container.encode(type, forKey: .type)
            try container.encode(symbol, forKey: .symbol)
            try container.encode(body, forKey: .body)
            try container.encode(status, forKey: .status)
            try container.encode(anchor, forKey: .anchor)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(updatedAt, forKey: .updatedAt)
            if let resolvedAt {
                try container.encode(resolvedAt, forKey: .resolvedAt)
            } else {
                try container.encodeNil(forKey: .resolvedAt)
            }
        }
    }
}
