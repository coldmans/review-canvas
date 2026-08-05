import SwiftUI

@main
struct ReviewCanvasApp: App {
    @StateObject private var document = MermaidDocument()

    var body: some Scene {
        WindowGroup("Review Canvas") {
            ContentView(document: document)
                .frame(minWidth: 720, minHeight: 480)
                .onOpenURL { url in
                    document.load(url)
                }
        }
        .defaultSize(width: 1_100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Mermaid 파일 열기…") {
                    document.openPanel()
                }
                .keyboardShortcut("o")

                Button("다시 불러오기") {
                    document.reload()
                }
                .keyboardShortcut("r")
                .disabled(document.fileURL == nil)
            }

            CommandMenu("보기") {
                Button("확대") {
                    document.zoomIn()
                }
                .keyboardShortcut("+")

                Button("축소") {
                    document.zoomOut()
                }
                .keyboardShortcut("-")

                Button("실제 크기") {
                    document.resetZoom()
                }
                .keyboardShortcut("0")
            }
        }
    }
}

private struct ContentView: View {
    @ObservedObject var document: MermaidDocument
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ZStack {
                MermaidWebView(source: document.source, zoom: document.zoom)

                if isDropTarget {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, dash: [10, 7])
                        )
                        .padding(18)
                        .allowsHitTesting(false)

                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 40))
                        Text("파일을 놓아 열기")
                            .font(.headline)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else {
                    return false
                }
                document.load(url)
                return true
            } isTargeted: { targeted in
                isDropTarget = targeted
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "파일을 열 수 없습니다",
            isPresented: Binding(
                get: { document.loadError != nil },
                set: { presented in
                    if !presented {
                        document.loadError = nil
                    }
                }
            )
        ) {
            Button("확인", role: .cancel) {
                document.loadError = nil
            }
        } message: {
            Text(document.loadError ?? "알 수 없는 오류")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                document.openPanel()
            } label: {
                Label("열기", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .help(".mmd, .mermaid 또는 Mermaid 코드 블록이 있는 Markdown 파일 열기")

            Button {
                document.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(document.fileURL == nil)
            .help("현재 파일 다시 불러오기")

            VStack(alignment: .leading, spacing: 1) {
                Text(document.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(document.fileURL?.deletingLastPathComponent().path ?? "파일을 열거나 창으로 드래그하세요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Button {
                    document.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("축소")

                Button {
                    document.resetZoom()
                } label: {
                    Text("\(Int(document.zoom * 100))%")
                        .monospacedDigit()
                        .frame(minWidth: 48)
                }
                .help("100%로 되돌리기")

                Button {
                    document.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("확대")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
