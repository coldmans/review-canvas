#if os(macOS)
import AppKit
import Foundation

enum MacPlatformSupport {
    static func revealInbox() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let inbox = base
            .appendingPathComponent("Review Canvas", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([inbox])
    }
}
#endif
