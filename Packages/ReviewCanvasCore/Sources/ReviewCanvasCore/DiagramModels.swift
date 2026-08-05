import Foundation

public enum DiagramRevisionStatus: String, Codable, CaseIterable, Sendable {
    case current
    case proposed
    case rejected
    case superseded
}

public struct DiagramRevision: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let parentRevisionID: UUID?
    public let sequence: Int
    public let source: String
    public internal(set) var status: DiagramRevisionStatus
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        parentRevisionID: UUID?,
        sequence: Int,
        source: String,
        status: DiagramRevisionStatus,
        createdAt: Date = Date()
    ) throws {
        guard sequence > 0 else {
            throw ReviewCanvasError.invalidRevisionSequence(sequence)
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReviewCanvasError.emptyDiagramSource
        }

        self.id = id
        self.parentRevisionID = parentRevisionID
        self.sequence = sequence
        self.source = source
        self.status = status
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            parentRevisionID: container.decodeIfPresent(UUID.self, forKey: .parentRevisionID),
            sequence: container.decode(Int.self, forKey: .sequence),
            source: container.decode(String.self, forKey: .source),
            status: container.decode(DiagramRevisionStatus.self, forKey: .status),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case parentRevisionID
        case sequence
        case source
        case status
        case createdAt
    }
}

public struct DiagramDocument: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public internal(set) var currentRevisionID: UUID
    public internal(set) var revisions: [DiagramRevision]
    public internal(set) var reviewMarks: [ReviewMark]
    public let createdAt: Date
    public internal(set) var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        initialSource: String,
        initialRevisionID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws {
        let initialRevision = try DiagramRevision(
            id: initialRevisionID,
            parentRevisionID: nil,
            sequence: 1,
            source: initialSource,
            status: .current,
            createdAt: createdAt
        )

        try self.init(
            id: id,
            title: title,
            currentRevisionID: initialRevisionID,
            revisions: [initialRevision],
            reviewMarks: [],
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    public init(
        id: UUID = UUID(),
        title: String,
        currentRevisionID: UUID,
        revisions: [DiagramRevision],
        reviewMarks: [ReviewMark],
        createdAt: Date,
        updatedAt: Date
    ) throws {
        try Self.validate(
            currentRevisionID: currentRevisionID,
            revisions: revisions,
            reviewMarks: reviewMarks
        )

        self.id = id
        self.title = title
        self.currentRevisionID = currentRevisionID
        self.revisions = revisions
        self.reviewMarks = reviewMarks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var currentRevision: DiagramRevision? {
        revision(id: currentRevisionID)
    }

    public var pendingRevision: DiagramRevision? {
        revisions.first { $0.status == .proposed }
    }

    public func revision(id: UUID) -> DiagramRevision? {
        revisions.first { $0.id == id }
    }

    public func reviewMark(id: UUID) -> ReviewMark? {
        reviewMarks.first { $0.id == id }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            title: container.decode(String.self, forKey: .title),
            currentRevisionID: container.decode(UUID.self, forKey: .currentRevisionID),
            revisions: container.decode([DiagramRevision].self, forKey: .revisions),
            reviewMarks: container.decode([ReviewMark].self, forKey: .reviewMarks),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt)
        )
    }

    private static func validate(
        currentRevisionID: UUID,
        revisions: [DiagramRevision],
        reviewMarks: [ReviewMark]
    ) throws {
        guard !revisions.isEmpty else {
            throw ReviewCanvasError.noRevisions
        }

        var revisionIDs = Set<UUID>()
        var revisionSequences = Set<Int>()
        for revision in revisions {
            guard revisionIDs.insert(revision.id).inserted else {
                throw ReviewCanvasError.duplicateRevision(revision.id)
            }
            guard revisionSequences.insert(revision.sequence).inserted else {
                throw ReviewCanvasError.duplicateRevisionSequence(revision.sequence)
            }
        }

        let revisionsByID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        for revision in revisions {
            if let parentRevisionID = revision.parentRevisionID,
               !revisionIDs.contains(parentRevisionID) {
                throw ReviewCanvasError.revisionParentNotFound(
                    revisionID: revision.id,
                    parentRevisionID: parentRevisionID
                )
            }
            if let parentRevisionID = revision.parentRevisionID,
               let parent = revisionsByID[parentRevisionID],
               parent.sequence >= revision.sequence {
                throw ReviewCanvasError.invalidRevisionParent(
                    revisionID: revision.id,
                    parentRevisionID: parentRevisionID
                )
            }
        }

        guard let selectedCurrent = revisions.first(where: { $0.id == currentRevisionID }) else {
            throw ReviewCanvasError.currentRevisionNotFound(currentRevisionID)
        }
        guard selectedCurrent.status == .current else {
            throw ReviewCanvasError.currentRevisionStatusMismatch(currentRevisionID)
        }
        guard revisions.lazy.filter({ $0.status == .current }).count == 1 else {
            throw ReviewCanvasError.multipleCurrentRevisions
        }
        guard revisions.lazy.filter({ $0.status == .proposed }).count <= 1 else {
            throw ReviewCanvasError.multiplePendingRevisions
        }

        var markIDs = Set<UUID>()
        for mark in reviewMarks {
            guard markIDs.insert(mark.id).inserted else {
                throw ReviewCanvasError.duplicateReviewMark(mark.id)
            }
            guard revisionIDs.contains(mark.revisionID) else {
                throw ReviewCanvasError.reviewMarkReferencesMissingRevision(
                    markID: mark.id,
                    revisionID: mark.revisionID
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case currentRevisionID
        case revisions
        case reviewMarks
        case createdAt
        case updatedAt
    }
}
