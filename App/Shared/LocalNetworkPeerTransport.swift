import CryptoKit
import Foundation
@preconcurrency import Network
import Security

enum LocalNetworkPeerError: Error, LocalizedError {
    case invalidPairingCode
    case peerNotFound
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidPairingCode:
            "6자리 연결 코드가 올바르지 않습니다."
        case .peerNotFound:
            "선택한 Mac을 더 이상 찾을 수 없습니다."
        case .notConnected:
            "연결된 Review Canvas 기기가 없습니다."
        }
    }
}

@MainActor
final class LocalNetworkPeerTransport: LocalPeerTransporting {
    static let serviceType = "_reviewcanvas._tcp"

    var eventHandler: ((LocalPeerTransportEvent) -> Void)?

    private let role: ReviewCanvasDeviceRole
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpoints: [String: NWEndpoint] = [:]
    private var peerNames: [String: String] = [:]
    private var connectedPeerName: String?

    init(role: ReviewCanvasDeviceRole) {
        self.role = role
    }

    func start(pairingCode: String?) {
        stop(emitStopped: false)

        switch role {
        case .mac:
            guard let pairingCode, Self.isValid(pairingCode) else {
                eventHandler?(.connectionState(.failed(
                    message: LocalNetworkPeerError.invalidPairingCode.localizedDescription
                )))
                return
            }
            startListener(pairingCode: pairingCode)
        case .ipad:
            startBrowser()
        }
    }

    func stop() {
        stop(emitStopped: true)
    }

    func connect(to peerID: String, pairingCode: String) {
        guard Self.isValid(pairingCode) else {
            eventHandler?(.connectionState(.failed(
                message: LocalNetworkPeerError.invalidPairingCode.localizedDescription
            )))
            return
        }
        guard let endpoint = endpoints[peerID] else {
            eventHandler?(.connectionState(.failed(
                message: LocalNetworkPeerError.peerNotFound.localizedDescription
            )))
            return
        }

        connection?.cancel()
        let peerName = peerNames[peerID] ?? "Mac"
        eventHandler?(.connectionState(.connecting(peerName: peerName)))
        activate(
            NWConnection(to: endpoint, using: Self.secureParameters(pairingCode: pairingCode)),
            peerName: peerName
        )
    }

    func send(_ data: Data) throws {
        guard let connection, case .ready = connection.state else {
            throw LocalNetworkPeerError.notConnected
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: UUID().uuidString,
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let error else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.eventHandler?(.connectionState(.failed(
                        message: error.localizedDescription
                    )))
                }
            }
        )
    }

    private func startListener(pairingCode: String) {
        do {
            let listener = try NWListener(using: Self.secureParameters(pairingCode: pairingCode))
            listener.service = NWListener.Service(
                name: Self.serviceName,
                type: Self.serviceType
            )
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    if let activeConnection = self?.connection,
                       case .ready = activeConnection.state {
                        connection.cancel()
                        return
                    }
                    self?.connection?.cancel()
                    self?.activate(connection, peerName: "iPad")
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            eventHandler?(.connectionState(.failed(message: error.localizedDescription)))
        }
    }

    private func startBrowser() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBrowserState(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.updatePeers(results)
            }
        }
        self.browser = browser
        eventHandler?(.connectionState(.searching))
        browser.start(queue: .main)
    }

    private func activate(_ connection: NWConnection, peerName: String) {
        self.connection = connection
        connectedPeerName = peerName
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleConnectionState(state, connection: connection, peerName: peerName)
            }
        }
        connection.start(queue: .main)
        receiveNextMessage(on: connection)
    }

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let connection else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else {
                    return
                }
                if let data, !data.isEmpty {
                    self.eventHandler?(.received(data))
                }
                if let error {
                    self.eventHandler?(.connectionState(.failed(message: error.localizedDescription)))
                    return
                }
                self.receiveNextMessage(on: connection)
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            eventHandler?(.connectionState(.advertising))
        case let .waiting(error), let .failed(error):
            eventHandler?(.connectionState(.failed(message: error.localizedDescription)))
        case .cancelled:
            if connection == nil {
                eventHandler?(.connectionState(.stopped))
            }
        default:
            break
        }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            eventHandler?(.connectionState(.searching))
        case let .waiting(error), let .failed(error):
            eventHandler?(.connectionState(.failed(message: error.localizedDescription)))
        case .cancelled:
            if connection == nil {
                eventHandler?(.connectionState(.stopped))
            }
        default:
            break
        }
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        connection: NWConnection,
        peerName: String
    ) {
        guard self.connection === connection else {
            return
        }
        switch state {
        case .ready:
            eventHandler?(.connectionState(.connected(peerName: peerName)))
        case let .waiting(error):
            eventHandler?(.connectionState(.connecting(peerName: peerName)))
            if case .tls = error {
                eventHandler?(.connectionState(.failed(
                    message: "연결 코드를 확인해 주세요. \(error.localizedDescription)"
                )))
            }
        case let .failed(error):
            eventHandler?(.connectionState(.failed(message: error.localizedDescription)))
            self.connection = nil
        case .cancelled:
            self.connection = nil
            connectedPeerName = nil
            eventHandler?(.connectionState(role == .mac ? .advertising : .searching))
        default:
            break
        }
    }

    private func updatePeers(_ results: Set<NWBrowser.Result>) {
        var updatedEndpoints: [String: NWEndpoint] = [:]
        var updatedNames: [String: String] = [:]
        var peers: [NearbyReviewCanvasPeer] = []

        for result in results {
            let id = String(describing: result.endpoint)
            let name: String
            if case let .service(serviceName, _, _, _) = result.endpoint {
                name = serviceName
            } else {
                name = "Review Canvas Mac"
            }
            updatedEndpoints[id] = result.endpoint
            updatedNames[id] = name
            peers.append(NearbyReviewCanvasPeer(id: id, name: name))
        }

        endpoints = updatedEndpoints
        peerNames = updatedNames
        eventHandler?(.peersChanged(peers.sorted { $0.name < $1.name }))
    }

    private func stop(emitStopped: Bool) {
        listener?.cancel()
        browser?.cancel()
        connection?.cancel()
        listener = nil
        browser = nil
        connection = nil
        connectedPeerName = nil
        endpoints = [:]
        peerNames = [:]
        eventHandler?(.peersChanged([]))
        if emitStopped {
            eventHandler?(.connectionState(.stopped))
        }
    }

    private static func secureParameters(pairingCode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        configurePSK(tls.securityProtocolOptions, pairingCode: pairingCode)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func configurePSK(
        _ options: sec_protocol_options_t,
        pairingCode: String
    ) {
        let identity = Data("review-canvas-v1".utf8)
        let key = Data(SHA256.hash(data: Data("review-canvas:\(pairingCode)".utf8)))
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            options,
            keyData as dispatch_data_t,
            identityData as dispatch_data_t
        )
        if let suite = tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    }

    private static func isValid(_ pairingCode: String) -> Bool {
        pairingCode.count == 6 && pairingCode.allSatisfy(\.isNumber)
    }

    private static var serviceName: String {
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        return "Review Canvas - \(host)"
    }
}
