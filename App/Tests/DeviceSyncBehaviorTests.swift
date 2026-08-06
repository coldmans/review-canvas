import CoreGraphics
import Foundation
import ReviewCanvasCore
import XCTest
@testable import ReviewCanvasApp

@MainActor
final class DeviceSyncBehaviorTests: XCTestCase {
    private let diagramID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
    private let revisionID = UUID(uuidString: "00000000-0000-4000-8000-000000000111")!
    private let deviceID = UUID(uuidString: "00000000-0000-4000-8000-000000000121")!
    private let start = Date(timeIntervalSince1970: 1_785_888_000)

    func testMacSendsCurrentWorkspaceAsSoonAsIPadConnects() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = makeWorkspace(in: directory)
        let transport = FakePeerTransport()
        let controller = ReviewCanvasSyncController(
            role: .mac,
            transport: transport,
            reviewOutbox: MCPReviewOutbox(
                directoryURL: directory.appendingPathComponent("ReviewOutbox/Pending")
            ),
            deviceID: deviceID,
            feedbackDebounceNanoseconds: 1_000_000
        )
        controller.bind(to: workspace)

        transport.emit(.connectionState(.connected(peerName: "Jinhyeong iPad")))

        let sent = try XCTUnwrap(transport.sentData.last)
        let envelope = try ReviewCanvasWireCodec.decode(sent)
        XCTAssertEqual(envelope.kind, .workspace)
        XCTAssertEqual(envelope.workspace?.document, workspace.document)
    }

    func testIPadAppliesWorkspaceThenReturnsDebouncedReviewFeedback() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = makeWorkspace(in: directory)
        let transport = FakePeerTransport()
        let controller = ReviewCanvasSyncController(
            role: .ipad,
            transport: transport,
            reviewOutbox: nil,
            deviceID: deviceID,
            feedbackDebounceNanoseconds: 1_000_000
        )
        controller.bind(to: workspace)
        transport.emit(.connectionState(.connected(peerName: "Jinhyeong Mac")))

        let remoteDocument = try DiagramDocument(
            id: diagramID,
            title: "AI architecture",
            initialSource: "flowchart LR\nAI --> Review",
            initialRevisionID: revisionID,
            createdAt: start
        )
        let incoming = PeerSyncEnvelope(
            senderID: UUID(),
            sentAt: start,
            workspace: WorkspaceSyncSnapshot(
                document: remoteDocument,
                drawingData: Data([0x01]),
                drawingUpdatedAt: start
            )
        )
        transport.emit(.received(try ReviewCanvasWireCodec.encode(incoming)))

        XCTAssertEqual(workspace.document.id, diagramID)
        XCTAssertEqual(workspace.drawingData, Data([0x01]))
        workspace.selectedReviewType = .explain
        workspace.addReviewMark(at: CGPoint(x: 0.5, y: 0.5), nodeID: "Review")
        try await Task<Never, Never>.sleep(nanoseconds: 20_000_000)

        let feedbackEnvelope = try ReviewCanvasWireCodec.decode(
            XCTUnwrap(transport.sentData.last)
        )
        XCTAssertEqual(feedbackEnvelope.kind, .feedback)
        XCTAssertEqual(feedbackEnvelope.feedback?.diagramID, diagramID)
        XCTAssertEqual(feedbackEnvelope.feedback?.marks.count, 1)
        XCTAssertEqual(feedbackEnvelope.feedback?.marks[0].anchor.targetID, "Review")
    }

    func testMacMergesIPadFeedbackAndExportsItForMCP() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = makeWorkspace(in: directory)
        workspace.applyRemoteWorkspace(
            WorkspaceSyncSnapshot(
                document: try DiagramDocument(
                    id: diagramID,
                    title: "AI architecture",
                    initialSource: "flowchart LR\nAI --> Review",
                    initialRevisionID: revisionID,
                    createdAt: start
                ),
                drawingData: Data(),
                drawingUpdatedAt: start
            )
        )
        let pendingDirectory = directory.appendingPathComponent("ReviewOutbox/Pending")
        let transport = FakePeerTransport()
        let controller = ReviewCanvasSyncController(
            role: .mac,
            transport: transport,
            reviewOutbox: MCPReviewOutbox(directoryURL: pendingDirectory),
            deviceID: deviceID,
            feedbackDebounceNanoseconds: 1_000_000
        )
        controller.bind(to: workspace)
        transport.emit(.connectionState(.connected(peerName: "Jinhyeong iPad")))
        let mark = try ReviewMark(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000131")!,
            revisionID: revisionID,
            type: .verify,
            anchor: try .node(nodeID: "Review", position: .center),
            body: "이 부분을 확인해 주세요.",
            createdAt: start,
            updatedAt: start
        )
        let feedback = try ReviewFeedbackSnapshot(
            diagramID: diagramID,
            revisionID: revisionID,
            marks: [mark],
            drawingData: Data([0x02]),
            drawingUpdatedAt: start.addingTimeInterval(1)
        )
        transport.emit(
            .received(
                try ReviewCanvasWireCodec.encode(
                    PeerSyncEnvelope(senderID: UUID(), sentAt: start, feedback: feedback)
                )
            )
        )

        XCTAssertEqual(workspace.document.reviewMarks, [mark])
        XCTAssertEqual(workspace.drawingData, Data([0x02]))
        let files = try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["exportId"] as? String, files[0].deletingPathExtension().lastPathComponent.dropFirst(7).description)
        let marks = try XCTUnwrap(json["marks"] as? [[String: Any]])
        XCTAssertEqual(marks[0]["diagramId"] as? String, diagramID.uuidString)
        XCTAssertEqual(marks[0]["revisionId"] as? String, revisionID.uuidString)
        XCTAssertEqual(marks[0]["symbol"] as? String, "!")
    }

    func testWireCodecRejectsOversizedMessagesBeforeDecoding() throws {
        XCTAssertThrowsError(
            try ReviewCanvasWireCodec.decode(
                Data(repeating: 0, count: ReviewCanvasWireCodec.maximumMessageBytes + 1)
            )
        ) {
            XCTAssertEqual($0 as? ReviewCanvasWireError, .messageTooLarge)
        }
    }

    private func makeWorkspace(in directory: URL) -> ReviewWorkspace {
        ReviewWorkspace(
            persistence: WorkspacePersistence(
                fileURL: directory.appendingPathComponent("workspace.json")
            ),
            inbox: ReviewCanvasInbox(
                directoryURL: directory.appendingPathComponent("Inbox")
            )
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewCanvasDeviceSyncTests-\(UUID().uuidString)")
    }
}

@MainActor
private final class FakePeerTransport: LocalPeerTransporting {
    var eventHandler: ((LocalPeerTransportEvent) -> Void)?
    private(set) var sentData: [Data] = []

    func start(pairingCode: String?) {}
    func stop() {}
    func connect(to peerID: String, pairingCode: String) {}

    func send(_ data: Data) throws {
        sentData.append(data)
    }

    func emit(_ event: LocalPeerTransportEvent) {
        eventHandler?(event)
    }
}
