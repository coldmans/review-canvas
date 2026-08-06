import Foundation
import ReviewCanvasCore

enum ReviewCanvasDeviceRole: String, Codable, Sendable {
    case mac
    case ipad
}

struct NearbyReviewCanvasPeer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum PeerConnectionState: Equatable, Sendable {
    case stopped
    case searching
    case advertising
    case connecting(peerName: String)
    case connected(peerName: String)
    case failed(message: String)

    var peerName: String? {
        switch self {
        case let .connecting(peerName), let .connected(peerName):
            peerName
        default:
            nil
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

enum LocalPeerTransportEvent: Sendable {
    case peersChanged([NearbyReviewCanvasPeer])
    case connectionState(PeerConnectionState)
    case received(Data)
}

@MainActor
protocol LocalPeerTransporting: AnyObject {
    var eventHandler: ((LocalPeerTransportEvent) -> Void)? { get set }

    func start(pairingCode: String?)
    func stop()
    func connect(to peerID: String, pairingCode: String)
    func send(_ data: Data) throws
}

@MainActor
final class ReviewCanvasSyncController: ObservableObject {
    @Published private(set) var peers: [NearbyReviewCanvasPeer] = []
    @Published private(set) var connectionState: PeerConnectionState = .stopped
    @Published private(set) var lastError: String?
    @Published var enteredPairingCode = ""

    let role: ReviewCanvasDeviceRole
    let pairingCode: String

    private let transport: any LocalPeerTransporting
    private let reviewOutbox: MCPReviewOutbox?
    private let deviceID: UUID
    private let feedbackDebounceNanoseconds: UInt64
    private weak var workspace: ReviewWorkspace?
    private var feedbackTask: Task<Void, Never>?
    private var seenMessageIDs: [UUID] = []
    private var lastExportedDiagramID: UUID?
    private var lastExportedRevisionID: UUID?
    private var lastExportedMarks: [ReviewMark] = []

    init(
        role: ReviewCanvasDeviceRole = .current,
        transport: (any LocalPeerTransporting)? = nil,
        reviewOutbox: MCPReviewOutbox? = MCPReviewOutbox(),
        deviceID: UUID = UUID(),
        feedbackDebounceNanoseconds: UInt64 = 400_000_000
    ) {
        self.role = role
        self.transport = transport ?? LocalNetworkPeerTransport(role: role)
        self.reviewOutbox = reviewOutbox
        self.deviceID = deviceID
        self.feedbackDebounceNanoseconds = feedbackDebounceNanoseconds
        pairingCode = role == .mac ? Self.makePairingCode() : ""

        self.transport.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    func bind(to workspace: ReviewWorkspace) {
        self.workspace = workspace
        workspace.localChangeHandler = { [weak self] change in
            self?.handleLocalChange(change)
        }
    }

    func start() {
        transport.start(pairingCode: role == .mac ? pairingCode : nil)
    }

    func stop() {
        feedbackTask?.cancel()
        transport.stop()
    }

    func connect(to peer: NearbyReviewCanvasPeer) {
        let code = enteredPairingCode.filter(\.isNumber)
        guard code.count == 6 else {
            lastError = "Mac에 표시된 6자리 연결 코드를 입력해 주세요."
            return
        }
        enteredPairingCode = code
        transport.connect(to: peer.id, pairingCode: code)
    }

    private func handle(_ event: LocalPeerTransportEvent) {
        switch event {
        case let .peersChanged(peers):
            self.peers = peers
        case let .connectionState(state):
            connectionState = state
            if case let .failed(message) = state {
                lastError = message
            } else if state.isConnected {
                lastError = nil
                if role == .mac {
                    sendWorkspace()
                }
            }
        case let .received(data):
            receive(data)
        }
    }

    private func receive(_ data: Data) {
        do {
            let envelope = try ReviewCanvasWireCodec.decode(data)
            guard envelope.senderID != deviceID, !seenMessageIDs.contains(envelope.messageID) else {
                return
            }
            remember(envelope.messageID)

            switch (role, envelope.kind) {
            case let (.mac, .feedback):
                guard let feedback = envelope.feedback, let workspace else {
                    return
                }
                if workspace.applyRemoteFeedback(feedback) {
                    exportReviewsIfNeeded()
                    sendWorkspace()
                }
            case let (.ipad, .workspace):
                guard let snapshot = envelope.workspace, let workspace else {
                    return
                }
                workspace.applyRemoteWorkspace(snapshot)
                scheduleFeedback()
            default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleLocalChange(_ change: WorkspaceChangeKind) {
        switch role {
        case .mac:
            if change == .reviews {
                exportReviewsIfNeeded()
            }
            sendWorkspace()
        case .ipad:
            scheduleFeedback()
        }
    }

    private func scheduleFeedback() {
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await Task<Never, Never>.sleep(
                    nanoseconds: feedbackDebounceNanoseconds
                )
            } catch {
                return
            }
            sendFeedback()
        }
    }

    private func sendWorkspace() {
        guard role == .mac, connectionState.isConnected, let workspace else {
            return
        }
        send(
            PeerSyncEnvelope(
                senderID: deviceID,
                workspace: workspace.workspaceSyncSnapshot()
            )
        )
    }

    private func sendFeedback() {
        guard role == .ipad, connectionState.isConnected, let workspace else {
            return
        }
        do {
            send(
                PeerSyncEnvelope(
                    senderID: deviceID,
                    feedback: try workspace.reviewFeedbackSnapshot()
                )
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func send(_ envelope: PeerSyncEnvelope) {
        do {
            try transport.send(ReviewCanvasWireCodec.encode(envelope))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func exportReviewsIfNeeded() {
        guard role == .mac, let workspace, let reviewOutbox else {
            return
        }
        let marks = workspace.currentReviewMarks
        guard !marks.isEmpty else {
            return
        }
        guard
            lastExportedDiagramID != workspace.document.id ||
            lastExportedRevisionID != workspace.document.currentRevisionID ||
            lastExportedMarks != marks
        else {
            return
        }

        do {
            try reviewOutbox.export(document: workspace.document)
            lastExportedDiagramID = workspace.document.id
            lastExportedRevisionID = workspace.document.currentRevisionID
            lastExportedMarks = marks
        } catch {
            lastError = "MCP로 검토 결과를 내보내지 못했습니다. \(error.localizedDescription)"
        }
    }

    private func remember(_ messageID: UUID) {
        seenMessageIDs.append(messageID)
        if seenMessageIDs.count > 512 {
            seenMessageIDs.removeFirst(seenMessageIDs.count - 512)
        }
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}

private extension ReviewCanvasDeviceRole {
    static var current: Self {
        #if os(macOS)
        .mac
        #else
        .ipad
        #endif
    }
}
