import Foundation
import XCTest
@testable import ReviewCanvasCore

final class PeerSyncTests: XCTestCase {
    private let diagramID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let revisionID = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
    private let senderID = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
    private let start = Date(timeIntervalSince1970: 1_785_888_000)

    func testWorkspaceEnvelopeRoundTripsWithOneVersionedPayload() throws {
        let snapshot = WorkspaceSyncSnapshot(
            document: try makeDocument(),
            drawingData: Data([0xCA, 0xFE]),
            drawingUpdatedAt: start.addingTimeInterval(1)
        )
        let envelope = PeerSyncEnvelope(
            messageID: UUID(uuidString: "00000000-0000-4000-8000-000000000031")!,
            senderID: senderID,
            sentAt: start.addingTimeInterval(2),
            workspace: snapshot
        )

        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(PeerSyncEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.kind, .workspace)
        XCTAssertEqual(decoded.workspace, snapshot)
        XCTAssertNil(decoded.feedback)
    }

    func testEnvelopeDecoderRejectsUnsupportedSchemaAndAmbiguousPayload() throws {
        let snapshot = WorkspaceSyncSnapshot(
            document: try makeDocument(),
            drawingData: Data(),
            drawingUpdatedAt: start
        )
        let valid = PeerSyncEnvelope(
            messageID: UUID(),
            senderID: senderID,
            sentAt: start,
            workspace: snapshot
        )
        let encoder = JSONEncoder()
        let validObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(valid)) as? [String: Any]
        )

        var future = validObject
        future["schemaVersion"] = 99
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PeerSyncEnvelope.self,
                from: JSONSerialization.data(withJSONObject: future)
            )
        ) { error in
            XCTAssertEqual(error as? PeerSyncError, .unsupportedSchema(99))
        }

        var ambiguous = validObject
        ambiguous["feedback"] = [
            "diagramID": diagramID.uuidString,
            "revisionID": revisionID.uuidString,
            "marks": [],
            "drawingData": "",
            "drawingUpdatedAt": start.timeIntervalSinceReferenceDate,
        ]
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PeerSyncEnvelope.self,
                from: JSONSerialization.data(withJSONObject: ambiguous)
            )
        ) { error in
            XCTAssertEqual(error as? PeerSyncError, .invalidPayload)
        }
    }

    func testFeedbackRejectsMarksFromAnotherRevision() throws {
        let otherRevisionID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
        let mark = try makeMark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000041")!,
            revisionID: otherRevisionID,
            updatedAt: start
        )

        XCTAssertThrowsError(
            try ReviewFeedbackSnapshot(
                diagramID: diagramID,
                revisionID: revisionID,
                marks: [mark],
                drawingData: Data(),
                drawingUpdatedAt: start
            )
        ) { error in
            XCTAssertEqual(
                error as? PeerSyncError,
                .markRevisionMismatch(
                    markID: mark.id,
                    expectedRevisionID: revisionID,
                    actualRevisionID: otherRevisionID
                )
            )
        }
    }

    func testFeedbackMergeUsesNewestMarkAndPreservesUnmentionedMarks() throws {
        let staleMarkID = UUID(uuidString: "00000000-0000-4000-8000-000000000051")!
        let untouchedMarkID = UUID(uuidString: "00000000-0000-4000-8000-000000000052")!
        let newMarkID = UUID(uuidString: "00000000-0000-4000-8000-000000000053")!
        var document = try makeDocument()

        let local = try ReviewMark(
            id: staleMarkID,
            revisionID: revisionID,
            type: .change,
            anchor: .canvas(position: .center),
            body: "Already being handled",
            createdAt: start,
            updatedAt: start
        )
        let untouched = try makeMark(
            id: untouchedMarkID,
            revisionID: revisionID,
            updatedAt: start.addingTimeInterval(5)
        )
        try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(local))
        try ReviewCanvasReducer.reduce(
            &document,
            action: .transitionReview(
                markID: staleMarkID,
                to: .inProgress,
                at: start.addingTimeInterval(20)
            )
        )
        try ReviewCanvasReducer.reduce(&document, action: .addReviewMark(untouched))

        let olderRemote = try makeMark(
            id: staleMarkID,
            revisionID: revisionID,
            updatedAt: start.addingTimeInterval(10)
        )
        let newRemote = try makeMark(
            id: newMarkID,
            revisionID: revisionID,
            updatedAt: start.addingTimeInterval(30)
        )
        let feedback = try ReviewFeedbackSnapshot(
            diagramID: diagramID,
            revisionID: revisionID,
            marks: [olderRemote, newRemote],
            drawingData: Data([0x01]),
            drawingUpdatedAt: start.addingTimeInterval(30)
        )

        let merged = try ReviewFeedbackMerger.merge(feedback, into: document)

        XCTAssertEqual(merged.reviewMark(id: staleMarkID)?.status, .inProgress)
        XCTAssertNotNil(merged.reviewMark(id: untouchedMarkID))
        XCTAssertEqual(merged.reviewMark(id: newMarkID), newRemote)
        XCTAssertEqual(merged.updatedAt, start.addingTimeInterval(30))
    }

    func testFeedbackMergeRejectsAnotherDiagramOrMissingRevision() throws {
        let feedback = try ReviewFeedbackSnapshot(
            diagramID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
            revisionID: revisionID,
            marks: [],
            drawingData: Data(),
            drawingUpdatedAt: start
        )

        XCTAssertThrowsError(try ReviewFeedbackMerger.merge(feedback, into: makeDocument())) {
            XCTAssertEqual(
                $0 as? PeerSyncError,
                .diagramMismatch(expected: diagramID, actual: feedback.diagramID)
            )
        }

        let missingRevisionID = UUID(uuidString: "00000000-0000-4000-8000-000000000098")!
        let missingRevisionFeedback = try ReviewFeedbackSnapshot(
            diagramID: diagramID,
            revisionID: missingRevisionID,
            marks: [],
            drawingData: Data(),
            drawingUpdatedAt: start
        )
        XCTAssertThrowsError(
            try ReviewFeedbackMerger.merge(missingRevisionFeedback, into: makeDocument())
        ) {
            XCTAssertEqual($0 as? PeerSyncError, .revisionNotFound(missingRevisionID))
        }
    }

    private func makeDocument() throws -> DiagramDocument {
        try DiagramDocument(
            id: diagramID,
            title: "Live review",
            initialSource: "flowchart LR\nMac --> iPad",
            initialRevisionID: revisionID,
            createdAt: start
        )
    }

    private func makeMark(id: UUID, revisionID: UUID, updatedAt: Date) throws -> ReviewMark {
        try ReviewMark(
            id: id,
            revisionID: revisionID,
            type: .explain,
            anchor: .canvas(position: .center),
            body: "Explain this",
            createdAt: start,
            updatedAt: updatedAt
        )
    }
}
