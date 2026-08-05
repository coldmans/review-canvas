import Combine
import CoreGraphics
import Foundation
import ReviewCanvasCore

@MainActor
final class ReviewWorkspace: ObservableObject {
    @Published private(set) var document: DiagramDocument
    @Published var selectedReviewType: ReviewMarkType?
    @Published var selectedMarkID: UUID?
    @Published var zoom = 1.0
    @Published var drawingData: Data
    @Published var isInkMode = false
    @Published var loadError: String?
    @Published var renderError: String?
    @Published private(set) var inboxCount = 0
    @Published private(set) var sourceURL: URL?

    private let persistence: WorkspacePersistence
    private let inbox: ReviewCanvasInbox
    private var canPersist = true

    init(
        persistence: WorkspacePersistence = WorkspacePersistence(),
        inbox: ReviewCanvasInbox = ReviewCanvasInbox()
    ) {
        self.persistence = persistence
        self.inbox = inbox

        switch Self.isUITesting ? .missing : persistence.load() {
        case let .loaded(stored):
            document = stored.document
            drawingData = stored.drawingData
        case .missing:
            document = Self.makeSampleDocument()
            drawingData = Data()
        case let .corrupt(error, backupURL):
            document = Self.makeSampleDocument()
            drawingData = Data()
            if let backupURL {
                loadError = "저장된 작업공간이 손상되어 \(backupURL.lastPathComponent)로 보관했습니다. \(error.localizedDescription)"
            } else {
                canPersist = false
                loadError = "저장된 작업공간을 읽지 못했습니다. 원본은 덮어쓰지 않습니다. \(error.localizedDescription)"
            }
        }

        refreshInboxCount()
    }

    var source: String {
        document.currentRevision?.source ?? Self.sampleSource
    }

    var title: String {
        document.title
    }

    var currentReviewMarks: [ReviewMark] {
        document.reviewMarks
            .filter { $0.revisionID == document.currentRevisionID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var selectedMark: ReviewMark? {
        guard let selectedMarkID else {
            return nil
        }
        return document.reviewMark(id: selectedMarkID)
    }

    func load(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            try replaceDocument(
                title: url.deletingPathExtension().lastPathComponent,
                source: MermaidSource.extract(from: contents)
            )
            sourceURL = url
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func addReviewMark(at normalizedPoint: CGPoint, nodeID: String? = nil) {
        guard let selectedReviewType else {
            return
        }

        do {
            let point = try NormalizedPoint(
                x: min(1, max(0, Double(normalizedPoint.x))),
                y: min(1, max(0, Double(normalizedPoint.y)))
            )
            let now = Date()
            let anchor: DiagramAnchor
            if let nodeID {
                anchor = try .node(nodeID: nodeID, position: point)
            } else {
                anchor = .canvas(position: point)
            }

            let mark = try ReviewMark(
                id: UUID(),
                revisionID: document.currentRevisionID,
                type: selectedReviewType,
                status: .open,
                anchor: anchor,
                body: selectedReviewType.defaultPrompt,
                createdAt: now,
                updatedAt: now,
                resolvedAt: nil
            )

            try apply(.addReviewMark(mark))
            selectedMarkID = mark.id
        } catch {
            loadError = error.localizedDescription
        }
    }

    func selectMark(_ markID: UUID) {
        selectedMarkID = markID
    }

    func transitionSelectedMark(to status: ReviewStatus) {
        guard let selectedMarkID else {
            return
        }

        do {
            try apply(.transitionReview(markID: selectedMarkID, to: status, at: Date()))
        } catch {
            loadError = error.localizedDescription
        }
    }

    func resolveSelectedMark() {
        transitionSelectedMark(to: .resolved)
    }

    func zoomIn() {
        zoom = min(2.5, (zoom + 0.1).rounded(toPlaces: 1))
    }

    func zoomOut() {
        zoom = max(0.5, (zoom - 0.1).rounded(toPlaces: 1))
    }

    func resetZoom() {
        zoom = 1.0
    }

    func updateDrawingData(_ data: Data) {
        drawingData = data
        persist()
    }

    func refreshInboxCount() {
        inboxCount = inbox.pendingCount
    }

    func importLatestInboxDiagram() {
        do {
            guard let item = try inbox.importNext() else {
                refreshInboxCount()
                return
            }
            try replaceDocument(
                title: item.title,
                source: item.source,
                diagramID: item.diagramID,
                revisionID: item.revisionID,
                createdAt: item.createdAt
            )
            loadError = nil
            refreshInboxCount()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func replaceDocument(
        title: String,
        source: String,
        diagramID: UUID = UUID(),
        revisionID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkspaceError.emptyDiagram
        }

        document = try DiagramDocument(
            id: diagramID,
            title: title.isEmpty ? "새 다이어그램" : title,
            initialSource: trimmed,
            initialRevisionID: revisionID,
            createdAt: createdAt
        )
        drawingData = Data()
        selectedMarkID = nil
        zoom = 1
        canPersist = true
        persist()
    }

    private func apply(_ action: ReviewCanvasAction) throws {
        var updatedDocument = document
        try ReviewCanvasReducer.reduce(&updatedDocument, action: action)
        document = updatedDocument
        persist()
    }

    private func persist() {
        guard !Self.isUITesting, canPersist else {
            return
        }
        persistence.save(document: document, drawingData: drawingData)
    }

    private static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    private static func makeSampleDocument() -> DiagramDocument {
        do {
            return try DiagramDocument(
                id: UUID(),
                title: "AI 검토 흐름 예제",
                initialSource: sampleSource,
                initialRevisionID: UUID(),
                createdAt: Date()
            )
        } catch {
            fatalError("기본 Mermaid 문서를 만들 수 없습니다: \(error)")
        }
    }

    private static let sampleSource = """
    flowchart LR
        AI["AI가 Mermaid 생성"] --> Send["iPad로 보내기"]
        Send --> Review["Apple Pencil로 검토"]
        Review --> Explain["? 설명 필요"]
        Review --> Change["✎ 수정 필요"]
        Review --> Verify["! 검토 필요"]
        Explain --> AI
        Change --> AI
        Verify --> AI
    """
}

struct PersistedWorkspace: Codable {
    let document: DiagramDocument
    let drawingData: Data
}

enum WorkspaceLoadResult {
    case missing
    case loaded(PersistedWorkspace)
    case corrupt(Error, backupURL: URL?)
}

struct WorkspacePersistence {
    private let overrideFileURL: URL?

    init(fileURL: URL? = nil) {
        overrideFileURL = fileURL
    }

    private var fileURL: URL {
        if let overrideFileURL {
            return overrideFileURL
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Review Canvas", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

    func load() -> WorkspaceLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .loaded(try decoder.decode(PersistedWorkspace.self, from: data))
        } catch {
            return .corrupt(error, backupURL: backupCorruptWorkspace())
        }
    }

    func save(document: DiagramDocument, drawingData: Data) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(PersistedWorkspace(document: document, drawingData: drawingData))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[ReviewCanvas] 작업공간 저장 실패: %@", error.localizedDescription)
        }
    }

    private func backupCorruptWorkspace() -> URL? {
        let backupURL = fileURL.deletingPathExtension().appendingPathExtension(
            "corrupt-\(UUID().uuidString).json"
        )

        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            NSLog("[ReviewCanvas] 손상된 작업공간 백업 실패: %@", error.localizedDescription)
            return nil
        }
    }
}

private enum WorkspaceError: LocalizedError {
    case emptyDiagram

    var errorDescription: String? {
        switch self {
        case .emptyDiagram:
            return "Mermaid 다이어그램이 비어 있습니다."
        }
    }
}

extension ReviewMarkType {
    var defaultPrompt: String {
        switch self {
        case .explain:
            return "이 부분은 설명이 더 필요합니다."
        case .change:
            return "이 부분은 수정이 필요합니다."
        case .verify:
            return "이 부분은 근거를 확인하고 검토해야 합니다."
        }
    }
}

extension ReviewStatus {
    var localizedTitle: String {
        switch self {
        case .open:
            return "대기"
        case .inProgress:
            return "처리 중"
        case .resolved:
            return "해결됨"
        case .dismissed:
            return "보류"
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
