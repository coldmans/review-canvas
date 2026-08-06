import Foundation

public enum ReviewCanvasAction: Equatable, Sendable {
    case proposeRevision(id: UUID, source: String, createdAt: Date)
    case approveRevision(id: UUID, at: Date)
    case rejectRevision(id: UUID, at: Date)
    case addReviewMark(ReviewMark)
    case transitionReview(markID: UUID, to: ReviewStatus, at: Date)
}

public enum ReviewCanvasReducer {
    public static func reduce(
        _ document: inout DiagramDocument,
        action: ReviewCanvasAction
    ) throws {
        switch action {
        case let .proposeRevision(id, source, createdAt):
            try proposeRevision(
                in: &document,
                id: id,
                source: source,
                createdAt: createdAt
            )
        case let .approveRevision(id, at):
            try finishProposal(in: &document, id: id, status: .current, at: at)
        case let .rejectRevision(id, at):
            try finishProposal(in: &document, id: id, status: .rejected, at: at)
        case let .addReviewMark(mark):
            try addReviewMark(mark, to: &document)
        case let .transitionReview(markID, status, at):
            try transitionReview(in: &document, markID: markID, to: status, at: at)
        }
    }

    private static func proposeRevision(
        in document: inout DiagramDocument,
        id: UUID,
        source: String,
        createdAt: Date
    ) throws {
        guard document.revision(id: id) == nil else {
            throw ReviewCanvasError.duplicateRevision(id)
        }
        if let pendingRevision = document.pendingRevision {
            throw ReviewCanvasError.pendingRevisionExists(pendingRevision.id)
        }

        let nextSequence = (document.revisions.map(\.sequence).max() ?? 0) + 1
        let revision = try DiagramRevision(
            id: id,
            parentRevisionID: document.currentRevisionID,
            sequence: nextSequence,
            source: source,
            status: .proposed,
            createdAt: createdAt
        )
        document.revisions.append(revision)
        document.updatedAt = max(document.updatedAt, createdAt)
    }

    private static func finishProposal(
        in document: inout DiagramDocument,
        id: UUID,
        status: DiagramRevisionStatus,
        at: Date
    ) throws {
        guard let proposalIndex = document.revisions.firstIndex(where: { $0.id == id }) else {
            throw ReviewCanvasError.revisionNotFound(id)
        }
        guard document.revisions[proposalIndex].status == .proposed else {
            throw ReviewCanvasError.revisionIsNotProposed(id)
        }

        if status == .current {
            guard let currentIndex = document.revisions.firstIndex(where: { $0.id == document.currentRevisionID }) else {
                throw ReviewCanvasError.currentRevisionNotFound(document.currentRevisionID)
            }
            document.revisions[currentIndex].status = .superseded
            document.currentRevisionID = id
        }

        document.revisions[proposalIndex].status = status
        document.updatedAt = max(document.updatedAt, at)
    }

    private static func addReviewMark(
        _ mark: ReviewMark,
        to document: inout DiagramDocument
    ) throws {
        guard document.reviewMark(id: mark.id) == nil else {
            throw ReviewCanvasError.duplicateReviewMark(mark.id)
        }
        guard document.revision(id: mark.revisionID) != nil else {
            throw ReviewCanvasError.reviewMarkReferencesMissingRevision(
                markID: mark.id,
                revisionID: mark.revisionID
            )
        }
        guard mark.status == .open else {
            throw ReviewCanvasError.reviewMarkMustStartOpen(mark.id)
        }

        document.reviewMarks.append(mark)
        document.updatedAt = max(document.updatedAt, mark.updatedAt)
    }

    private static func transitionReview(
        in document: inout DiagramDocument,
        markID: UUID,
        to status: ReviewStatus,
        at: Date
    ) throws {
        guard let markIndex = document.reviewMarks.firstIndex(where: { $0.id == markID }) else {
            throw ReviewCanvasError.reviewMarkNotFound(markID)
        }

        let currentStatus = document.reviewMarks[markIndex].status
        guard currentStatus != status else {
            return
        }
        guard currentStatus.canTransition(to: status) else {
            throw ReviewCanvasError.invalidReviewStatusTransition(from: currentStatus, to: status)
        }
        guard at >= document.reviewMarks[markIndex].updatedAt else {
            throw ReviewCanvasError.staleReviewTimestamp(markID)
        }

        document.reviewMarks[markIndex].status = status
        document.reviewMarks[markIndex].updatedAt = at
        document.reviewMarks[markIndex].resolvedAt = status == .resolved ? at : nil
        document.updatedAt = max(document.updatedAt, at)
    }
}
