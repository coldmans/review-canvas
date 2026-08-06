import ReviewCanvasCore
import SwiftUI
import UniformTypeIdentifiers

struct ReviewCanvasRootView: View {
    @ObservedObject var workspace: ReviewWorkspace
    @ObservedObject var syncController: ReviewCanvasSyncController
    @State private var isFileImporterPresented = false
    @State private var isSyncPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ReviewSidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        } detail: {
            VStack(spacing: 0) {
                ReviewToolbar(
                    workspace: workspace,
                    syncController: syncController,
                    openFile: { isFileImporterPresented = true },
                    showSync: { isSyncPresented = true }
                )
                Divider()
                ReviewDocumentView(workspace: workspace)
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.plainText, .sourceCode],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    workspace.load(url)
                }
            case let .failure(error):
                workspace.loadError = error.localizedDescription
            }
        }
        .alert(
            "Review Canvas 오류",
            isPresented: Binding(
                get: { workspace.loadError != nil },
                set: { if !$0 { workspace.loadError = nil } }
            )
        ) {
            Button("확인", role: .cancel) { workspace.loadError = nil }
        } message: {
            Text(workspace.loadError ?? "알 수 없는 오류")
        }
        .sheet(isPresented: $isSyncPresented) {
            DeviceSyncPanel(syncController: syncController)
        }
        .task {
            syncController.bind(to: workspace)
            syncController.start()
            #if os(macOS)
            await workspace.monitorInbox()
            #endif
        }
        .onDisappear {
            syncController.stop()
        }
    }
}

private struct ReviewToolbar: View {
    @ObservedObject var workspace: ReviewWorkspace
    @ObservedObject var syncController: ReviewCanvasSyncController
    let openFile: () -> Void
    let showSync: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: openFile) {
                Label("열기", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            #if os(macOS)
            Button {
                workspace.importNextInboxDiagram()
            } label: {
                Label("AI Inbox \(workspace.inboxCount)", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .help("로컬 MCP가 보낸 다음 대기 다이어그램 가져오기")
            #endif

            Button(action: showSync) {
                Label(syncController.toolbarTitle, systemImage: syncController.toolbarSymbol)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("device-sync")

            Divider().frame(height: 24)

            ReviewTypePicker(workspace: workspace)

            #if os(iOS)
            Button {
                workspace.isInkMode.toggle()
                if workspace.isInkMode {
                    workspace.selectedReviewType = nil
                }
            } label: {
                Label("필기", systemImage: workspace.isInkMode ? "pencil.tip.crop.circle.badge.plus" : "pencil.tip")
            }
            .modifier(ReviewSelectionButtonStyle(isSelected: workspace.isInkMode))
            .accessibilityIdentifier("pencil-mode")
            #endif

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(workspace.title)
                    .font(.headline)
                    .lineLimit(1)
                if let renderError = workspace.renderError {
                    Text(renderError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text("검토 \(workspace.currentReviewMarks.filter { $0.status != .resolved }.count)개 대기")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
                Button(action: workspace.zoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button(action: workspace.resetZoom) {
                    Text("\(Int(workspace.zoom * 100))%")
                        .monospacedDigit()
                        .frame(minWidth: 48)
                }
                Button(action: workspace.zoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct DeviceSyncPanel: View {
    @ObservedObject var syncController: ReviewCanvasSyncController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("연결 상태") {
                    Label(
                        syncController.connectionState.localizedTitle,
                        systemImage: syncController.toolbarSymbol
                    )
                    if let error = syncController.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if syncController.role == .mac {
                    Section("iPad 연결 코드") {
                        Text(syncController.pairingCode)
                            .font(.system(size: 38, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        Text("iPad에서 이 Mac을 선택한 뒤 코드를 입력하세요. 코드는 TLS 암호화 연결에 사용됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Mac 연결") {
                        TextField("6자리 연결 코드", text: $syncController.enteredPairingCode)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            #endif

                        if syncController.peers.isEmpty {
                            ContentUnavailableView(
                                "주변 Mac을 찾는 중",
                                systemImage: "wifi",
                                description: Text("두 기기에서 Review Canvas를 열고 같은 Wi-Fi에 연결하세요.")
                            )
                        } else {
                            ForEach(syncController.peers) { peer in
                                Button {
                                    syncController.connect(to: peer)
                                } label: {
                                    Label(peer.name, systemImage: "desktopcomputer")
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("검색·공유 다시 시작") {
                        syncController.start()
                    }
                    Button("연결 중지", role: .destructive) {
                        syncController.stop()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("기기 연결")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }
}

private struct ReviewTypePicker: View {
    @ObservedObject var workspace: ReviewWorkspace

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ReviewMarkType.allCases, id: \.self) { type in
                Button {
                    workspace.isInkMode = false
                    let isAlreadySelected = workspace.selectedReviewType == type
                    workspace.selectedReviewType = isAlreadySelected ? nil : type
                } label: {
                    HStack(spacing: 5) {
                        Text(type.displaySymbol).fontWeight(.bold)
                        Text(type.localizedTitle)
                    }
                }
                .modifier(
                    ReviewSelectionButtonStyle(isSelected: workspace.selectedReviewType == type)
                )
                .tint(type.tint)
                .accessibilityIdentifier("review-type-\(type.rawValue)")
            }
        }
    }
}

private struct ReviewSelectionButtonStyle: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct ReviewDocumentView: View {
    @ObservedObject var workspace: ReviewWorkspace
    @State private var geometry = DiagramViewportGeometry.unavailable

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MermaidWebView(
                    source: workspace.source,
                    zoom: workspace.zoom,
                    onGeometryChange: { geometry = $0 },
                    onError: { error in
                        workspace.renderError = error
                        if error != nil {
                            geometry = .unavailable
                        }
                    }
                )

                if workspace.selectedReviewType != nil
                    && !workspace.isInkMode
                    && geometry.isAvailable {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            guard geometry.contains(location, in: proxy.size) else {
                                return
                            }
                            let point = geometry.normalizedPoint(for: location, in: proxy.size)
                            workspace.addReviewMark(at: point, nodeID: geometry.nodeID(at: point))
                        }
                        .accessibilityRepresentation {
                            Button("다이어그램 검토 캔버스") {
                                let point = CGPoint(x: 0.5, y: 0.5)
                                workspace.addReviewMark(
                                    at: point,
                                    nodeID: geometry.nodeID(at: point)
                                )
                            }
                            .accessibilityIdentifier("diagram-review-canvas")
                        }
                }

                if geometry.isAvailable {
                    ForEach(workspace.currentReviewMarks) { mark in
                        ReviewMarkButton(
                            mark: mark,
                            isSelected: workspace.selectedMarkID == mark.id,
                            action: { workspace.selectMark(mark.id) }
                        )
                        .position(
                            geometry.location(
                                forNormalizedX: mark.anchor.position.x,
                                y: mark.anchor.position.y,
                                in: proxy.size
                            )
                        )
                        .allowsHitTesting(!workspace.isInkMode)
                    }
                }

                #if os(iOS)
                PencilCanvasView(
                    drawingData: Binding(
                        get: { workspace.drawingData },
                        set: { workspace.updateDrawingData($0) }
                    ),
                    isDrawingEnabled: workspace.isInkMode
                )
                .allowsHitTesting(workspace.isInkMode)
                #endif
            }
            .clipped()
        }
        .background(PlatformColors.canvasBackground)
        .onChange(of: workspace.source) { _, _ in
            geometry = .unavailable
        }
    }
}

private struct ReviewMarkButton: View {
    let mark: ReviewMark
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(mark.status == .resolved ? Color.green : mark.type.tint)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Circle()
                    .strokeBorder(isSelected ? Color.primary : Color.white.opacity(0.9), lineWidth: isSelected ? 3 : 2)
                Text(mark.status == .resolved ? "✓" : mark.type.displaySymbol)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: isSelected ? 38 : 34, height: isSelected ? 38 : 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mark.type.localizedTitle), \(mark.status.localizedTitle)")
        .accessibilityIdentifier("review-mark")
    }
}

private struct ReviewSidebarView: View {
    @ObservedObject var workspace: ReviewWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("검토 목록")
                    .font(.title2.bold())
                Spacer()
                Text("\(workspace.currentReviewMarks.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            .padding()

            if workspace.currentReviewMarks.isEmpty {
                ContentUnavailableView(
                    "표시된 검토가 없습니다",
                    systemImage: "checkmark.circle",
                    description: Text("상단에서 기호를 고른 뒤 다이어그램을 탭하세요.")
                )
            } else {
                List(selection: $workspace.selectedMarkID) {
                    ForEach(workspace.currentReviewMarks) { mark in
                        ReviewMarkRow(mark: mark)
                            .tag(mark.id)
                    }
                }
                .listStyle(.sidebar)
            }

            if let mark = workspace.selectedMark {
                Divider()
                ReviewMarkDetail(mark: mark, workspace: workspace)
                    .padding()
            }
        }
        .navigationTitle("Review Canvas")
    }
}

private struct ReviewMarkRow: View {
    let mark: ReviewMark

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(mark.status == .resolved ? "✓" : mark.type.displaySymbol)
                .font(.headline)
                .foregroundStyle(mark.status == .resolved ? .green : mark.type.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(mark.type.localizedTitle)
                    .font(.headline)
                Text(mark.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(mark.status.localizedTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(mark.status == .resolved ? .green : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ReviewMarkDetail: View {
    let mark: ReviewMark
    @ObservedObject var workspace: ReviewWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(mark.type.displaySymbol) \(mark.type.localizedTitle)")
                    .font(.headline)
                Spacer()
                Text(mark.status.localizedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mark.status == .resolved ? .green : mark.type.tint)
            }

            Text(mark.body)
                .font(.callout)
                .foregroundStyle(.secondary)

            if mark.status == .resolved {
                Label("해결됨", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("해결됨으로 표시") {
                    workspace.resolveSelectedMark()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("resolve-review-mark")
            }
        }
    }
}

private enum PlatformColors {
    static var canvasBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

private extension ReviewMarkType {
    var localizedTitle: String {
        switch self {
        case .explain:
            return "설명"
        case .change:
            return "수정"
        case .verify:
            return "검토"
        }
    }

    var tint: Color {
        switch self {
        case .explain:
            return .blue
        case .change:
            return .orange
        case .verify:
            return .red
        }
    }
}

private extension ReviewCanvasSyncController {
    var toolbarTitle: String {
        switch connectionState {
        case let .connected(peerName):
            return peerName
        case .advertising:
            return "iPad 대기 중"
        case .searching:
            return peers.isEmpty ? "Mac 찾는 중" : "Mac \(peers.count)대"
        case let .connecting(peerName):
            return "\(peerName) 연결 중"
        case .failed:
            return "연결 확인"
        case .stopped:
            return "기기 연결"
        }
    }

    var toolbarSymbol: String {
        connectionState.isConnected ? "ipad.and.iphone" : "wifi"
    }
}

private extension PeerConnectionState {
    var localizedTitle: String {
        switch self {
        case .stopped:
            "중지됨"
        case .searching:
            "주변 Mac 검색 중"
        case .advertising:
            "iPad 연결 대기 중"
        case let .connecting(peerName):
            "\(peerName)에 연결 중"
        case let .connected(peerName):
            "\(peerName) 연결됨"
        case let .failed(message):
            "연결 오류: \(message)"
        }
    }
}
