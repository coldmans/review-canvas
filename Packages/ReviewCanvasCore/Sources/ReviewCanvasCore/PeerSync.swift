import Foundation

public enum PeerSyncMessageKind: String, Codable, CaseIterable, Sendable {
    case workspace
    case feedback
}

public enum PeerSyncError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidPayload
    case duplicateMark(UUID)
    case markRevisionMismatch(
        markID: UUID,
        expectedRevisionID: UUID,
        actualRevisionID: UUID
    )
    case diagramMismatch(expected: UUID, actual: UUID)
    case revisionNotFound(UUID)
}

extension PeerSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "지원하지 않는 기기 동기화 버전입니다: \(version)"
        case .invalidPayload:
            "기기 동기화 메시지에는 하나의 payload만 있어야 합니다."
        case let .duplicateMark(markID):
            "동기화 메시지에 중복된 검토 표시가 있습니다: \(markID)"
        case let .markRevisionMismatch(markID, expectedRevisionID, actualRevisionID):
            "검토 표시 \(markID)가 revision \(expectedRevisionID) 대신 \(actualRevisionID)를 참조합니다."
        case let .diagramMismatch(expected, actual):
            "다른 다이어그램의 검토 결과입니다. 예상: \(expected), 수신: \(actual)"
        case let .revisionNotFound(revisionID):
            "검토 결과가 존재하지 않는 revision을 참조합니다: \(revisionID)"
        }
    }
}

public struct WorkspaceSyncSnapshot: Codable, Equatable, Sendable {
    public let document: DiagramDocument
    public let drawingData: Data
    public let drawingUpdatedAt: Date

    public init(
        document: DiagramDocument,
        drawingData: Data,
        drawingUpdatedAt: Date
    ) {
        self.document = document
        self.drawingData = drawingData
        self.drawingUpdatedAt = drawingUpdatedAt
    }
}

public struct ReviewFeedbackSnapshot: Codable, Equatable, Sendable {
    public let diagramID: UUID
    public let revisionID: UUID
    public let marks: [ReviewMark]
    public let drawingData: Data
    public let drawingUpdatedAt: Date

    public init(
        diagramID: UUID,
        revisionID: UUID,
        marks: [ReviewMark],
        drawingData: Data,
        drawingUpdatedAt: Date
    ) throws {
        var markIDs = Set<UUID>()
        for mark in marks {
            guard markIDs.insert(mark.id).inserted else {
                throw PeerSyncError.duplicateMark(mark.id)
            }
            guard mark.revisionID == revisionID else {
                throw PeerSyncError.markRevisionMismatch(
                    markID: mark.id,
                    expectedRevisionID: revisionID,
                    actualRevisionID: mark.revisionID
                )
            }
        }

        self.diagramID = diagramID
        self.revisionID = revisionID
        self.marks = marks
        self.drawingData = drawingData
        self.drawingUpdatedAt = drawingUpdatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            diagramID: container.decode(UUID.self, forKey: .diagramID),
            revisionID: container.decode(UUID.self, forKey: .revisionID),
            marks: container.decode([ReviewMark].self, forKey: .marks),
            drawingData: container.decode(Data.self, forKey: .drawingData),
            drawingUpdatedAt: container.decode(Date.self, forKey: .drawingUpdatedAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case diagramID
        case revisionID
        case marks
        case drawingData
        case drawingUpdatedAt
    }
}

public struct PeerSyncEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let messageID: UUID
    public let senderID: UUID
    public let sentAt: Date
    public let workspace: WorkspaceSyncSnapshot?
    public let feedback: ReviewFeedbackSnapshot?

    public var kind: PeerSyncMessageKind {
        workspace == nil ? .feedback : .workspace
    }

    public init(
        messageID: UUID = UUID(),
        senderID: UUID,
        sentAt: Date = Date(),
        workspace: WorkspaceSyncSnapshot
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.messageID = messageID
        self.senderID = senderID
        self.sentAt = sentAt
        self.workspace = workspace
        feedback = nil
    }

    public init(
        messageID: UUID = UUID(),
        senderID: UUID,
        sentAt: Date = Date(),
        feedback: ReviewFeedbackSnapshot
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.messageID = messageID
        self.senderID = senderID
        self.sentAt = sentAt
        workspace = nil
        self.feedback = feedback
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PeerSyncError.unsupportedSchema(schemaVersion)
        }

        let workspace = try container.decodeIfPresent(
            WorkspaceSyncSnapshot.self,
            forKey: .workspace
        )
        let feedback = try container.decodeIfPresent(
            ReviewFeedbackSnapshot.self,
            forKey: .feedback
        )
        guard (workspace == nil) != (feedback == nil) else {
            throw PeerSyncError.invalidPayload
        }

        self.schemaVersion = schemaVersion
        messageID = try container.decode(UUID.self, forKey: .messageID)
        senderID = try container.decode(UUID.self, forKey: .senderID)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        self.workspace = workspace
        self.feedback = feedback
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case messageID
        case senderID
        case sentAt
        case workspace
        case feedback
    }
}

public enum ReviewFeedbackMerger {
    public static func merge(
        _ feedback: ReviewFeedbackSnapshot,
        into document: DiagramDocument
    ) throws -> DiagramDocument {
        guard document.id == feedback.diagramID else {
            throw PeerSyncError.diagramMismatch(
                expected: document.id,
                actual: feedback.diagramID
            )
        }
        guard document.revision(id: feedback.revisionID) != nil else {
            throw PeerSyncError.revisionNotFound(feedback.revisionID)
        }

        var marks = document.reviewMarks
        for incoming in feedback.marks {
            if let index = marks.firstIndex(where: { $0.id == incoming.id }) {
                if incoming.updatedAt > marks[index].updatedAt {
                    marks[index] = incoming
                }
            } else {
                marks.append(incoming)
            }
        }

        let mostRecentMark = marks.map(\.updatedAt).max() ?? document.updatedAt
        return try DiagramDocument(
            id: document.id,
            title: document.title,
            currentRevisionID: document.currentRevisionID,
            revisions: document.revisions,
            reviewMarks: marks,
            createdAt: document.createdAt,
            updatedAt: max(document.updatedAt, mostRecentMark)
        )
    }
}
