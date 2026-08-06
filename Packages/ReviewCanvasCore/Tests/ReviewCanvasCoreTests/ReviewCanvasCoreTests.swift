import Foundation
import XCTest
@testable import ReviewCanvasCore

final class ReviewCanvasCoreTests: XCTestCase {
    private let documentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let firstRevisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let secondRevisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    private let thirdRevisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    private let markID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    func testMarkTypesExposeStableRawValuesAndDisplayMetadata() {
        XCTAssertEqual(ReviewMarkType.allCases.map(\.rawValue), ["explain", "change", "verify"])
        XCTAssertEqual(ReviewMarkType.explain.displaySymbol, "?")
        XCTAssertEqual(ReviewMarkType.change.displaySymbol, "✎")
        XCTAssertEqual(ReviewMarkType.verify.displaySymbol, "!")
        XCTAssertFalse(ReviewMarkType.explain.displayTitle.isEmpty)
        XCTAssertFalse(ReviewMarkType.change.displayTitle.isEmpty)
        XCTAssertFalse(ReviewMarkType.verify.displayTitle.isEmpty)
    }

    func testNormalizedPointAcceptsBoundaryValues() throws {
        XCTAssertEqual(try NormalizedPoint(x: 1, y: 0), NormalizedPoint.topRight)
        XCTAssertEqual(try NormalizedPoint(x: 0, y: 1).x, 0)
        XCTAssertEqual(try NormalizedPoint(x: 0, y: 1).y, 1)
    }

    func testNormalizedPointRejectsOutOfRangeAndNonFiniteCoordinates() {
        assertInvalidCoordinate(x: -0.001, y: 0.5, axis: .x)
        assertInvalidCoordinate(x: 0.5, y: 1.001, axis: .y)
        assertInvalidCoordinate(x: .nan, y: 0.5, axis: .x)
        assertInvalidCoordinate(x: 0.5, y: .infinity, axis: .y)
    }

    func testAnchorVariantsRoundTripWithStableDiscriminatorAndConveniences() throws {
        let point = try NormalizedPoint(x: 0.25, y: 0.75)
        let anchors: [DiagramAnchor] = [
            try .node(nodeID: "flow-start", position: point),
            try .edge(edgeID: "flow-start-to-end", position: point),
            .canvas(position: point),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        for anchor in anchors {
            let data = try encoder.encode(anchor)
            let decoded = try decoder.decode(DiagramAnchor.self, from: data)

            XCTAssertEqual(decoded, anchor)
            XCTAssertEqual(decoded.position, point)
            let json = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(json.contains("\"kind\":\"" + anchor.kind.rawValue + "\""))
        }

        XCTAssertEqual(anchors[0].targetID, "flow-start")
        XCTAssertEqual(anchors[1].targetID, "flow-start-to-end")
        XCTAssertNil(anchors[2].targetID)
    }

    func testSemanticAnchorsRejectBlankIdentifiers() throws {
        let point = try NormalizedPoint(x: 0.5, y: 0.5)

        XCTAssertThrowsError(try DiagramAnchor.node(nodeID: "   ", position: point)) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .emptyAnchorIdentifier(.node))
        }
        XCTAssertThrowsError(try DiagramAnchor.edge(edgeID: "\n", position: point)) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .emptyAnchorIdentifier(.edge))
        }
    }

    func testInvalidNormalizedPointCannotEnterThroughJSON() {
        let json = Data(#"{"x":1.5,"y":0.25}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(NormalizedPoint.self, from: json))
    }

    func testInitialDocumentCreatesOneCurrentRevision() throws {
        let document = try makeDocument()

        XCTAssertEqual(document.id, documentID)
        XCTAssertEqual(document.currentRevisionID, firstRevisionID)
        XCTAssertEqual(document.currentRevision?.source, "flowchart LR\nA --> B")
        XCTAssertEqual(document.currentRevision?.status, .current)
        XCTAssertEqual(document.revisions.map(\.sequence), [1])
        XCTAssertTrue(document.reviewMarks.isEmpty)
        XCTAssertNil(document.pendingRevision)
    }

    func testDocumentRoundTripsThroughCodableWithoutLosingInvariants() throws {
        var document = try makeDocument()
        try ReviewCanvasReducer.reduce(
            &document,
            action: .proposeRevision(
                id: secondRevisionID,
                source: "flowchart LR\nA --> C",
                createdAt: start.addingTimeInterval(10)
            )
        )
        let mark = try makeMark()
        try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(mark))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(DiagramDocument.self, from: encoder.encode(document))
        XCTAssertEqual(decoded, document)
    }

    func testFullDocumentInitializerRejectsMissingCurrentRevision() throws {
        let rejected = try DiagramRevision(
            id: firstRevisionID,
            parentRevisionID: nil,
            sequence: 1,
            source: "flowchart LR\nA --> B",
            status: .rejected,
            createdAt: start
        )

        XCTAssertThrowsError(
            try DiagramDocument(
                id: documentID,
                title: "System map",
                currentRevisionID: firstRevisionID,
                revisions: [rejected],
                reviewMarks: [],
                createdAt: start,
                updatedAt: start
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .currentRevisionStatusMismatch(firstRevisionID))
        }
    }

    func testRevisionRejectsEmptySourceAndInvalidSequence() {
        XCTAssertThrowsError(
            try DiagramRevision(
                id: firstRevisionID,
                parentRevisionID: nil,
                sequence: 0,
                source: "flowchart LR\nA --> B",
                status: .current,
                createdAt: start
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .invalidRevisionSequence(0))
        }

        XCTAssertThrowsError(
            try DiagramRevision(
                id: firstRevisionID,
                parentRevisionID: nil,
                sequence: 1,
                source: " \n ",
                status: .current,
                createdAt: start
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .emptyDiagramSource)
        }
    }

    func testDocumentRejectsSelfReferentialAndForwardRevisionParents() throws {
        let selfReferential = try DiagramRevision(
            id: firstRevisionID,
            parentRevisionID: firstRevisionID,
            sequence: 1,
            source: "flowchart LR\nA --> B",
            status: .current,
            createdAt: start
        )
        XCTAssertThrowsError(
            try DiagramDocument(
                id: documentID,
                title: "Broken history",
                currentRevisionID: firstRevisionID,
                revisions: [selfReferential],
                reviewMarks: [],
                createdAt: start,
                updatedAt: start
            )
        ) { error in
            XCTAssertEqual(
                error as? ReviewCanvasError,
                .invalidRevisionParent(revisionID: firstRevisionID, parentRevisionID: firstRevisionID)
            )
        }

        let forwardParent = try DiagramRevision(
            id: firstRevisionID,
            parentRevisionID: secondRevisionID,
            sequence: 1,
            source: "flowchart LR\nA --> B",
            status: .current,
            createdAt: start
        )
        let laterRevision = try DiagramRevision(
            id: secondRevisionID,
            parentRevisionID: nil,
            sequence: 2,
            source: "flowchart LR\nA --> C",
            status: .rejected,
            createdAt: start.addingTimeInterval(10)
        )
        XCTAssertThrowsError(
            try DiagramDocument(
                id: documentID,
                title: "Broken history",
                currentRevisionID: firstRevisionID,
                revisions: [forwardParent, laterRevision],
                reviewMarks: [],
                createdAt: start,
                updatedAt: start.addingTimeInterval(10)
            )
        ) { error in
            XCTAssertEqual(
                error as? ReviewCanvasError,
                .invalidRevisionParent(revisionID: firstRevisionID, parentRevisionID: secondRevisionID)
            )
        }
    }

    func testProposingRevisionAppendsChildWithoutOverwritingCurrentSource() throws {
        var document = try makeDocument()
        let proposalTime = start.addingTimeInterval(30)

        try ReviewCanvasReducer.reduce(
            &document,
            action: .proposeRevision(
                id: secondRevisionID,
                source: "flowchart LR\nA --> C",
                createdAt: proposalTime
            )
        )

        XCTAssertEqual(document.revisions.count, 2)
        XCTAssertEqual(document.currentRevisionID, firstRevisionID)
        XCTAssertEqual(document.currentRevision?.source, "flowchart LR\nA --> B")
        XCTAssertEqual(document.pendingRevision?.id, secondRevisionID)
        XCTAssertEqual(document.pendingRevision?.parentRevisionID, firstRevisionID)
        XCTAssertEqual(document.pendingRevision?.sequence, 2)
        XCTAssertEqual(document.pendingRevision?.status, .proposed)
        XCTAssertEqual(document.updatedAt, proposalTime)
    }

    func testOnlyOneRevisionProposalCanBePending() throws {
        var document = try makeDocument()
        try proposeSecondRevision(in: &document)

        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(
                &document,
                action: .proposeRevision(
                    id: thirdRevisionID,
                    source: "flowchart LR\nA --> D",
                    createdAt: start.addingTimeInterval(20)
                )
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .pendingRevisionExists(secondRevisionID))
        }
    }

    func testDuplicateRevisionIdentifierIsRejected() throws {
        var document = try makeDocument()

        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(
                &document,
                action: .proposeRevision(
                    id: firstRevisionID,
                    source: "flowchart LR\nA --> C",
                    createdAt: start.addingTimeInterval(10)
                )
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .duplicateRevision(firstRevisionID))
        }
    }

    func testApprovingProposalSupersedesPriorCurrentRevision() throws {
        var document = try makeDocument()
        try proposeSecondRevision(in: &document)
        let approvalTime = start.addingTimeInterval(20)

        try ReviewCanvasReducer.reduce(
            &document,
            action: .approveRevision(id: secondRevisionID, at: approvalTime)
        )

        XCTAssertEqual(document.currentRevisionID, secondRevisionID)
        XCTAssertEqual(document.revision(id: firstRevisionID)?.status, .superseded)
        XCTAssertEqual(document.revision(id: secondRevisionID)?.status, .current)
        XCTAssertNil(document.pendingRevision)
        XCTAssertEqual(document.updatedAt, approvalTime)
    }

    func testRejectingProposalKeepsCurrentAndAllowsLaterProposal() throws {
        var document = try makeDocument()
        try proposeSecondRevision(in: &document)

        try ReviewCanvasReducer.reduce(
            &document,
            action: .rejectRevision(id: secondRevisionID, at: start.addingTimeInterval(20))
        )
        try ReviewCanvasReducer.reduce(
            &document,
            action: .proposeRevision(
                id: thirdRevisionID,
                source: "flowchart LR\nA --> D",
                createdAt: start.addingTimeInterval(30)
            )
        )

        XCTAssertEqual(document.currentRevisionID, firstRevisionID)
        XCTAssertEqual(document.revision(id: secondRevisionID)?.status, .rejected)
        XCTAssertEqual(document.pendingRevision?.id, thirdRevisionID)
        XCTAssertEqual(document.pendingRevision?.sequence, 3)
    }

    func testOnlyProposedRevisionCanBeApprovedOrRejected() throws {
        var document = try makeDocument()
        let missingID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(
                &document,
                action: .approveRevision(id: firstRevisionID, at: start)
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .revisionIsNotProposed(firstRevisionID))
        }
        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(
                &document,
                action: .rejectRevision(id: missingID, at: start)
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .revisionNotFound(missingID))
        }
    }

    func testAddingReviewMarkRequiresExistingRevisionAndUniqueIdentifier() throws {
        var document = try makeDocument()
        let mark = try makeMark()

        try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(mark))
        XCTAssertEqual(document.reviewMarks, [mark])

        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(mark))
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .duplicateReviewMark(markID))
        }

        let unknownRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000098")!
        let orphan = try makeMark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            revisionID: unknownRevision
        )
        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(orphan))
        ) { error in
            XCTAssertEqual(
                error as? ReviewCanvasError,
                .reviewMarkReferencesMissingRevision(markID: orphan.id, revisionID: unknownRevision)
            )
        }
    }

    func testNewReviewMarkMustStartOpen() throws {
        var document = try makeDocument()
        let alreadyResolved = try makeMark(status: .resolved, resolvedAt: start)

        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(alreadyResolved))
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .reviewMarkMustStartOpen(markID))
        }
    }

    func testReviewStatusTransitionsAndResolutionTimestamp() throws {
        var document = try makeDocument()
        try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(try makeMark()))

        let inProgressTime = start.addingTimeInterval(10)
        try ReviewCanvasReducer.reduce(
            &document,
            action: .transitionReview(markID: markID, to: .inProgress, at: inProgressTime)
        )
        XCTAssertEqual(document.reviewMark(id: markID)?.status, .inProgress)
        XCTAssertNil(document.reviewMark(id: markID)?.resolvedAt)

        let resolvedTime = start.addingTimeInterval(20)
        try ReviewCanvasReducer.reduce(
            &document,
            action: .transitionReview(markID: markID, to: .resolved, at: resolvedTime)
        )
        XCTAssertEqual(document.reviewMark(id: markID)?.status, .resolved)
        XCTAssertEqual(document.reviewMark(id: markID)?.resolvedAt, resolvedTime)

        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(
                &document,
                action: .transitionReview(markID: markID, to: .inProgress, at: resolvedTime)
            )
        ) { error in
            XCTAssertEqual(
                error as? ReviewCanvasError,
                .invalidReviewStatusTransition(from: .resolved, to: .inProgress)
            )
        }

        let reopenedTime = start.addingTimeInterval(30)
        try ReviewCanvasReducer.reduce(
            &document,
            action: .transitionReview(markID: markID, to: .open, at: reopenedTime)
        )
        XCTAssertEqual(document.reviewMark(id: markID)?.status, .open)
        XCTAssertNil(document.reviewMark(id: markID)?.resolvedAt)
    }

    func testDismissedMarkMustBeReopenedBeforeWorkResumes() throws {
        var document = try makeDocument()
        try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(try makeMark()))
        try ReviewCanvasReducer.reduce(
            &document,
            action: .transitionReview(markID: markID, to: .dismissed, at: start.addingTimeInterval(10))
        )

        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(
                &document,
                action: .transitionReview(markID: markID, to: .resolved, at: start.addingTimeInterval(20))
            )
        ) { error in
            XCTAssertEqual(
                error as? ReviewCanvasError,
                .invalidReviewStatusTransition(from: .dismissed, to: .resolved)
            )
        }
    }

    func testIdempotentStatusTransitionDoesNotChangeTimestamps() throws {
        var document = try makeDocument()
        try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(try makeMark()))
        let priorDocumentTimestamp = document.updatedAt
        let priorMarkTimestamp = document.reviewMark(id: markID)?.updatedAt

        try ReviewCanvasReducer.reduce(
            &document,
            action: .transitionReview(markID: markID, to: .open, at: start.addingTimeInterval(99))
        )

        XCTAssertEqual(document.updatedAt, priorDocumentTimestamp)
        XCTAssertEqual(document.reviewMark(id: markID)?.updatedAt, priorMarkTimestamp)
    }

    func testTransitioningUnknownReviewMarkFails() throws {
        var document = try makeDocument()
        let unknownID = UUID(uuidString: "00000000-0000-0000-0000-000000000097")!

        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(
                &document,
                action: .transitionReview(markID: unknownID, to: .resolved, at: start)
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .reviewMarkNotFound(unknownID))
        }
    }

    func testReviewMarkResolutionTimestampInvariant() throws {
        XCTAssertThrowsError(
            try makeMark(status: .resolved, resolvedAt: nil)
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .resolvedReviewRequiresTimestamp(markID))
        }
        XCTAssertThrowsError(
            try makeMark(status: .open, resolvedAt: start)
        ) { error in
            XCTAssertEqual(
                error as? ReviewCanvasError,
                .nonResolvedReviewHasTimestamp(markID: markID, status: .open)
            )
        }
    }

    func testReviewMarkRejectsBlankBodyAndRegressingTimestamps() throws {
        XCTAssertThrowsError(
            try ReviewMark(
                id: markID,
                revisionID: firstRevisionID,
                type: .verify,
                anchor: .canvas(position: NormalizedPoint.center),
                body: " \n ",
                createdAt: start
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .emptyReviewBody(markID))
        }

        XCTAssertThrowsError(
            try ReviewMark(
                id: markID,
                revisionID: firstRevisionID,
                type: .verify,
                anchor: .canvas(position: NormalizedPoint.center),
                body: "Check this",
                createdAt: start,
                updatedAt: start.addingTimeInterval(-1)
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .invalidReviewChronology(markID))
        }
    }

    func testReviewTransitionRejectsTimestampOlderThanMark() throws {
        var document = try makeDocument()
        try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(try makeMark()))
        try ReviewCanvasReducer.reduce(
            &document,
            action: .transitionReview(markID: markID, to: .inProgress, at: start.addingTimeInterval(10))
        )

        XCTAssertThrowsError(
            try ReviewCanvasReducer.reduce(
                &document,
                action: .transitionReview(markID: markID, to: .resolved, at: start.addingTimeInterval(5))
            )
        ) { error in
            XCTAssertEqual(error as? ReviewCanvasError, .staleReviewTimestamp(markID))
        }
        XCTAssertEqual(document.reviewMark(id: markID)?.status, .inProgress)
    }

    func testDocumentUpdatedAtNeverRegressesAcrossRevisionActions() throws {
        var document = try makeDocument()
        try proposeSecondRevision(in: &document)

        try ReviewCanvasReducer.reduce(
            &document,
            action: .approveRevision(id: secondRevisionID, at: start.addingTimeInterval(5))
        )

        XCTAssertEqual(document.updatedAt, start.addingTimeInterval(10))
    }

    func testEveryDomainErrorProvidesActionableDescription() {
        let parentID = UUID(uuidString: "00000000-0000-0000-0000-000000000096")!
        let errors: [ReviewCanvasError] = [
            .invalidNormalizedCoordinate(axis: .x, value: -1),
            .emptyAnchorIdentifier(.node),
            .emptyDiagramSource,
            .invalidRevisionSequence(0),
            .noRevisions,
            .duplicateRevision(firstRevisionID),
            .duplicateRevisionSequence(1),
            .revisionNotFound(firstRevisionID),
            .revisionParentNotFound(revisionID: secondRevisionID, parentRevisionID: parentID),
            .invalidRevisionParent(revisionID: secondRevisionID, parentRevisionID: parentID),
            .currentRevisionNotFound(firstRevisionID),
            .currentRevisionStatusMismatch(firstRevisionID),
            .multipleCurrentRevisions,
            .pendingRevisionExists(secondRevisionID),
            .multiplePendingRevisions,
            .revisionIsNotProposed(secondRevisionID),
            .duplicateReviewMark(markID),
            .reviewMarkNotFound(markID),
            .reviewMarkReferencesMissingRevision(markID: markID, revisionID: firstRevisionID),
            .reviewMarkMustStartOpen(markID),
            .resolvedReviewRequiresTimestamp(markID),
            .nonResolvedReviewHasTimestamp(markID: markID, status: .open),
            .emptyReviewBody(markID),
            .invalidReviewChronology(markID),
            .staleReviewTimestamp(markID),
            .invalidReviewStatusTransition(from: .resolved, to: .inProgress),
        ]

        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    func testActorStoreSerializesActionsAndReturnsSnapshots() async throws {
        let store = ReviewCanvasStore(document: try makeDocument())

        let proposed = try await store.send(
            .proposeRevision(
                id: secondRevisionID,
                source: "flowchart LR\nA --> C",
                createdAt: start.addingTimeInterval(10)
            )
        )
        XCTAssertEqual(proposed.pendingRevision?.id, secondRevisionID)

        let approved = try await store.send(
            .approveRevision(id: secondRevisionID, at: start.addingTimeInterval(20))
        )
        let snapshot = await store.snapshot()

        XCTAssertEqual(approved.currentRevisionID, secondRevisionID)
        XCTAssertEqual(snapshot, approved)
    }

    private func makeDocument() throws -> DiagramDocument {
        try DiagramDocument(
            id: documentID,
            title: "System map",
            initialSource: "flowchart LR\nA --> B",
            initialRevisionID: firstRevisionID,
            createdAt: start
        )
    }

    private func makeMark(
        id: UUID? = nil,
        revisionID: UUID? = nil,
        status: ReviewStatus = .open,
        resolvedAt: Date? = nil
    ) throws -> ReviewMark {
        try ReviewMark(
            id: id ?? markID,
            revisionID: revisionID ?? firstRevisionID,
            type: .explain,
            status: status,
            anchor: .canvas(position: NormalizedPoint(x: 0.4, y: 0.6)),
            body: "Why is this dependency here?",
            createdAt: start,
            updatedAt: start,
            resolvedAt: resolvedAt
        )
    }

    private func proposeSecondRevision(in document: inout DiagramDocument) throws {
        try ReviewCanvasReducer.reduce(
            &document,
            action: .proposeRevision(
                id: secondRevisionID,
                source: "flowchart LR\nA --> C",
                createdAt: start.addingTimeInterval(10)
            )
        )
    }

    private func assertInvalidCoordinate(
        x: Double,
        y: Double,
        axis: NormalizedAxis,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try NormalizedPoint(x: x, y: y), file: file, line: line) { error in
            guard case let ReviewCanvasError.invalidNormalizedCoordinate(actualAxis, _) = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertEqual(actualAxis, axis, file: file, line: line)
        }
    }
}
