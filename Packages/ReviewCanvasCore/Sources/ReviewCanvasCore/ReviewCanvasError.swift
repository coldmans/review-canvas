import Foundation

public enum NormalizedAxis: String, Codable, CaseIterable, Sendable {
    case x
    case y
}

public enum AnchorKind: String, Codable, CaseIterable, Sendable {
    case node
    case edge
    case canvas
}

public enum ReviewCanvasError: Error, Equatable, Sendable {
    case invalidNormalizedCoordinate(axis: NormalizedAxis, value: Double)
    case emptyAnchorIdentifier(AnchorKind)
    case emptyDiagramSource
    case invalidRevisionSequence(Int)
    case noRevisions
    case duplicateRevision(UUID)
    case duplicateRevisionSequence(Int)
    case revisionNotFound(UUID)
    case revisionParentNotFound(revisionID: UUID, parentRevisionID: UUID)
    case invalidRevisionParent(revisionID: UUID, parentRevisionID: UUID)
    case currentRevisionNotFound(UUID)
    case currentRevisionStatusMismatch(UUID)
    case multipleCurrentRevisions
    case pendingRevisionExists(UUID)
    case multiplePendingRevisions
    case revisionIsNotProposed(UUID)
    case duplicateReviewMark(UUID)
    case reviewMarkNotFound(UUID)
    case reviewMarkReferencesMissingRevision(markID: UUID, revisionID: UUID)
    case reviewMarkMustStartOpen(UUID)
    case resolvedReviewRequiresTimestamp(UUID)
    case nonResolvedReviewHasTimestamp(markID: UUID, status: ReviewStatus)
    case emptyReviewBody(UUID)
    case invalidReviewChronology(UUID)
    case staleReviewTimestamp(UUID)
    case invalidReviewStatusTransition(from: ReviewStatus, to: ReviewStatus)
}

extension ReviewCanvasError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidNormalizedCoordinate(axis, value):
            "Normalized \(axis.rawValue) coordinate must be finite and within 0...1; received \(value)."
        case let .emptyAnchorIdentifier(kind):
            "A \(kind.rawValue) anchor requires a non-empty identifier."
        case .emptyDiagramSource:
            "A diagram revision cannot have an empty Mermaid source."
        case let .invalidRevisionSequence(sequence):
            "Revision sequence must be greater than zero; received \(sequence)."
        case .noRevisions:
            "A diagram document requires at least one revision."
        case let .duplicateRevision(id):
            "Revision \(id) already exists."
        case let .duplicateRevisionSequence(sequence):
            "Revision sequence \(sequence) already exists."
        case let .revisionNotFound(id):
            "Revision \(id) was not found."
        case let .revisionParentNotFound(revisionID, parentRevisionID):
            "Revision \(revisionID) references missing parent \(parentRevisionID)."
        case let .invalidRevisionParent(revisionID, parentRevisionID):
            "Revision \(revisionID) must reference an earlier parent, not \(parentRevisionID)."
        case let .currentRevisionNotFound(id):
            "Current revision \(id) was not found."
        case let .currentRevisionStatusMismatch(id):
            "Current revision \(id) does not have current status."
        case .multipleCurrentRevisions:
            "A document can contain only one current revision."
        case let .pendingRevisionExists(id):
            "Proposed revision \(id) must be approved or rejected first."
        case .multiplePendingRevisions:
            "A document can contain only one proposed revision."
        case let .revisionIsNotProposed(id):
            "Revision \(id) is not awaiting approval."
        case let .duplicateReviewMark(id):
            "Review mark \(id) already exists."
        case let .reviewMarkNotFound(id):
            "Review mark \(id) was not found."
        case let .reviewMarkReferencesMissingRevision(markID, revisionID):
            "Review mark \(markID) references missing revision \(revisionID)."
        case let .reviewMarkMustStartOpen(id):
            "New review mark \(id) must start open."
        case let .resolvedReviewRequiresTimestamp(id):
            "Resolved review mark \(id) requires a resolution timestamp."
        case let .nonResolvedReviewHasTimestamp(id, status):
            "Review mark \(id) with status \(status.rawValue) cannot have a resolution timestamp."
        case let .emptyReviewBody(id):
            "Review mark \(id) requires a non-empty body."
        case let .invalidReviewChronology(id):
            "Review mark \(id) contains timestamps outside its valid chronology."
        case let .staleReviewTimestamp(id):
            "Review mark \(id) cannot move backward in time."
        case let .invalidReviewStatusTransition(from, to):
            "Review status cannot transition directly from \(from.rawValue) to \(to.rawValue)."
        }
    }
}
