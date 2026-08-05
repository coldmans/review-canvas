import ReviewCanvasCore
import SwiftUI
import UniformTypeIdentifiers

struct ReviewCanvasRootView: View {
    @ObservedObject var workspace: ReviewWorkspace
    @State private var isFileImporterPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ReviewSidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        } detail: {
            VStack(spacing: 0) {
                ReviewToolbar(workspace: workspace) {
                    isFileImporterPresented = true
                }
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
        .onAppear { workspace.refreshInboxCount() }
    }
}

private struct ReviewToolbar: View {
    @ObservedObject var workspace: ReviewWorkspace
    let openFile: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: openFile) {
                Label("열기", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            #if os(macOS)
            Button {
                workspace.importLatestInboxDiagram()
            } label: {
                Label("AI Inbox \(workspace.inboxCount)", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(workspace.inboxCount == 0)
            .help("로컬 MCP가 보낸 최신 다이어그램 열기")
            #endif

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
                    onError: { workspace.renderError = $0 }
                )

                if workspace.selectedReviewType != nil && !workspace.isInkMode {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
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
