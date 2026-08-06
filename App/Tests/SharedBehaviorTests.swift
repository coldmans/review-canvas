import CoreGraphics
import XCTest
@testable import ReviewCanvasApp

final class SharedBehaviorTests: XCTestCase {
    @MainActor
    func testZoomInRaisesScaleAndZoomOutLowersIt() {
        let workspace = ReviewWorkspace()

        workspace.zoomIn()
        XCTAssertEqual(workspace.zoom, 1.1, accuracy: 0.001)

        workspace.zoomOut()
        workspace.zoomOut()
        XCTAssertEqual(workspace.zoom, 0.9, accuracy: 0.001)
    }

    func testMermaidSourceExtractsFirstFencedBlock() {
        let markdown = """
        # Architecture

        ```mermaid
        flowchart LR
            A --> B
        ```

        trailing text
        """

        XCTAssertEqual(MermaidSource.extract(from: markdown), "flowchart LR\n    A --> B")
    }

    func testMermaidSourceLeavesPlainSourceUntouched() {
        let source = "flowchart TD\nA --> B"
        XCTAssertEqual(MermaidSource.extract(from: source), source)
    }

    func testViewportGeometryMapsPointsInBothDirections() {
        let geometry = DiagramViewportGeometry(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        let size = CGSize(width: 1_000, height: 800)

        let location = geometry.location(forNormalizedX: 0.4, y: 0.75, in: size)
        let normalized = geometry.normalizedPoint(for: location, in: size)

        XCTAssertEqual(location.x, 300, accuracy: 0.001)
        XCTAssertEqual(location.y, 400, accuracy: 0.001)
        XCTAssertEqual(normalized.x, 0.4, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.75, accuracy: 0.001)
    }

    func testViewportGeometrySelectsSmallestContainingSemanticNode() {
        let geometry = DiagramViewportGeometry(
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            nodes: [
                DiagramNodeGeometry(id: "outer", x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                DiagramNodeGeometry(id: "inner", x: 0.4, y: 0.4, width: 0.2, height: 0.2)
            ]
        )

        XCTAssertEqual(geometry.nodeID(at: CGPoint(x: 0.5, y: 0.5)), "inner")
        XCTAssertNil(geometry.nodeID(at: CGPoint(x: 0.95, y: 0.95)))
    }

    func testUnavailableViewportRejectsInteractionAndDiagramBoundsExcludeOutsideTaps() {
        XCTAssertFalse(DiagramViewportGeometry.unavailable.isAvailable)

        let geometry = DiagramViewportGeometry(x: 0.2, y: 0.25, width: 0.5, height: 0.4)
        let size = CGSize(width: 1_000, height: 800)

        XCTAssertTrue(geometry.contains(CGPoint(x: 300, y: 300), in: size))
        XCTAssertFalse(geometry.contains(CGPoint(x: 100, y: 300), in: size))
        XCTAssertFalse(geometry.contains(CGPoint(x: 800, y: 300), in: size))
    }

    func testInboxImportsOnlyDiagramEnvelopeAndArchivesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewCanvasInboxTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try writeInboxEnvelope(to: directory, createdAt: "2026-08-05T00:00:00.123Z")
        try Data("{}".utf8).write(to: directory.appendingPathComponent("store.json"))

        let inbox = ReviewCanvasInbox(directoryURL: directory)
        XCTAssertEqual(inbox.pendingCount, 1)

        let imported = try XCTUnwrap(inbox.importNext())
        XCTAssertEqual(imported.diagramID.uuidString, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(imported.revisionID.uuidString, "00000000-0000-0000-0000-000000000011")
        XCTAssertEqual(imported.title, "Deployment")
        XCTAssertEqual(imported.source, "flowchart LR\nA --> B")
        XCTAssertEqual(imported.createdAt.timeIntervalSince1970, 1_785_888_000.123, accuracy: 0.000_1)
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("Processed/diagram-00000000-0000-0000-0000-000000000001.json")
                    .path
            )
        )
    }

    func testInboxAlsoImportsWholeSecondTimestamp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewCanvasInboxDateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeInboxEnvelope(to: directory, createdAt: "2026-08-05T00:00:00Z")

        let imported = try XCTUnwrap(ReviewCanvasInbox(directoryURL: directory).importNext())

        XCTAssertEqual(imported.title, "Deployment")
    }

    func testInboxRejectsMalformedTimestampWithoutArchivingEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewCanvasInboxInvalidDateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeInboxEnvelope(to: directory, createdAt: "not-a-date")

        let inbox = ReviewCanvasInbox(directoryURL: directory)

        XCTAssertThrowsError(try inbox.importNext())
        XCTAssertEqual(inbox.pendingCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("Processed/diagram-00000000-0000-0000-0000-000000000001.json")
                    .path
            )
        )
    }

    @MainActor
    func testWorkspaceMonitorsInboxThatArrivesAfterLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewCanvasInboxMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workspace = ReviewWorkspace(
            persistence: WorkspacePersistence(fileURL: directory.appendingPathComponent("workspace.json")),
            inbox: ReviewCanvasInbox(directoryURL: directory.appendingPathComponent("Inbox"))
        )
        XCTAssertEqual(workspace.inboxCount, 0)

        let monitor = Task {
            await workspace.monitorInbox(pollIntervalNanoseconds: 10_000_000)
        }
        defer { monitor.cancel() }

        try await Task<Never, Never>.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(workspace.inboxCount, 0)

        let inboxDirectory = directory.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        try writeInboxEnvelope(to: inboxDirectory, createdAt: "2026-08-05T00:00:00.123Z")

        for _ in 0..<50 where workspace.inboxCount == 0 {
            try await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(workspace.inboxCount, 1)
    }

    func testInboxIgnoresSymlinksNonUUIDNamesAndOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewCanvasInboxSafetyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outsideFile = directory.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(
                "diagram-00000000-0000-0000-0000-000000000001.json"
            ),
            withDestinationURL: outsideFile
        )
        try Data("{}".utf8).write(to: directory.appendingPathComponent("diagram-not-a-uuid.json"))
        try Data(repeating: 0, count: 3 * 1_024 * 1_024 + 1).write(
            to: directory.appendingPathComponent(
                "diagram-00000000-0000-0000-0000-000000000002.json"
            )
        )

        XCTAssertEqual(ReviewCanvasInbox(directoryURL: directory).pendingCount, 0)
    }

    @MainActor
    func testCorruptWorkspaceIsBackedUpBeforeShowingSampleDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewCanvasWorkspaceSafetyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workspaceURL = directory.appendingPathComponent("workspace.json")
        try Data("not-json".utf8).write(to: workspaceURL)

        let workspace = ReviewWorkspace(
            persistence: WorkspacePersistence(fileURL: workspaceURL),
            inbox: ReviewCanvasInbox(directoryURL: directory.appendingPathComponent("Inbox"))
        )

        XCTAssertNotNil(workspace.loadError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceURL.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("workspace.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
    }
}

private func writeInboxEnvelope(to directory: URL, createdAt: String) throws {
    let envelope = """
    {
      "schemaVersion": 1,
      "diagramId": "00000000-0000-0000-0000-000000000001",
      "title": "Deployment",
      "createdAt": "\(createdAt)",
      "revision": {
        "id": "00000000-0000-0000-0000-000000000011",
        "parentRevisionId": null,
        "sequence": 1,
        "status": "current",
        "source": "flowchart LR\\nA --> B"
      }
    }
    """
    try Data(envelope.utf8).write(
        to: directory.appendingPathComponent("diagram-00000000-0000-0000-0000-000000000001.json")
    )
}
