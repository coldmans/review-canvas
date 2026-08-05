import SwiftUI

@main
struct ReviewCanvasApp: App {
    @StateObject private var workspace = ReviewWorkspace()

    var body: some Scene {
        WindowGroup("Review Canvas") {
            ReviewCanvasRootView(workspace: workspace)
                .onOpenURL { workspace.load($0) }
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 620)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1_220, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("보기") {
                Button("확대") { workspace.zoomIn() }
                    .keyboardShortcut("+")
                Button("축소") { workspace.zoomOut() }
                    .keyboardShortcut("-")
                Button("실제 크기") { workspace.resetZoom() }
                    .keyboardShortcut("0")
            }
        }
        #endif
    }
}
