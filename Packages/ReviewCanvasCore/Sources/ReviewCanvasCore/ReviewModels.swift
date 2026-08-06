import Foundation

public enum ReviewMarkType: String, Codable, CaseIterable, Sendable {
    case explain
    case change
    case verify

    public var displaySymbol: String {
        switch self {
        case .explain:
            "?"
        case .change:
            "✎"
        case .verify:
            "!"
        }
    }

    public var displayTitle: String {
        switch self {
        case .explain:
            "Explanation"
        case .change:
            "Change"
        case .verify:
            "Verification"
        }
    }
}

public enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case open
    case inProgress
    case resolved
    case dismissed

    public func canTransition(to next: Self) -> Bool {
        if self == next {
            return true
        }

        return switch (self, next) {
        case (.open, .inProgress),
             (.open, .resolved),
             (.open, .dismissed),
             (.inProgress, .open),
             (.inProgress, .resolved),
             (.inProgress, .dismissed),
             (.resolved, .open),
             (.dismissed, .open):
            true
        default:
            false
        }
    }
}

public struct ReviewMark: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let revisionID: UUID
    public let type: ReviewMarkType
    public internal(set) var status: ReviewStatus
    public let anchor: DiagramAnchor
    public let body: String
    public let createdAt: Date
    public internal(set) var updatedAt: Date
    public internal(set) var resolvedAt: Date?

    public init(
        id: UUID = UUID(),
        revisionID: UUID,
        type: ReviewMarkType,
        status: ReviewStatus = .open,
        anchor: DiagramAnchor,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        resolvedAt: Date? = nil
    ) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReviewCanvasError.emptyReviewBody(id)
        }

        let effectiveUpdatedAt = updatedAt ?? createdAt
        guard effectiveUpdatedAt >= createdAt else {
            throw ReviewCanvasError.invalidReviewChronology(id)
        }
        if status == .resolved, resolvedAt == nil {
            throw ReviewCanvasError.resolvedReviewRequiresTimestamp(id)
        }
        if status != .resolved, resolvedAt != nil {
            throw ReviewCanvasError.nonResolvedReviewHasTimestamp(markID: id, status: status)
        }
        if let resolvedAt,
           !(createdAt...effectiveUpdatedAt).contains(resolvedAt) {
            throw ReviewCanvasError.invalidReviewChronology(id)
        }

        self.id = id
        self.revisionID = revisionID
        self.type = type
        self.status = status
        self.anchor = anchor
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = effectiveUpdatedAt
        self.resolvedAt = resolvedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            revisionID: container.decode(UUID.self, forKey: .revisionID),
            type: container.decode(ReviewMarkType.self, forKey: .type),
            status: container.decode(ReviewStatus.self, forKey: .status),
            anchor: container.decode(DiagramAnchor.self, forKey: .anchor),
            body: container.decode(String.self, forKey: .body),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            resolvedAt: container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case revisionID
        case type
        case status
        case anchor
        case body
        case createdAt
        case updatedAt
        case resolvedAt
    }
}
