import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class MermaidDocument: ObservableObject {
    @Published private(set) var source: String
    @Published private(set) var fileURL: URL?
    @Published private(set) var zoom = 1.0
    @Published var loadError: String?

    init() {
        source = Self.sampleDiagram
    }

    var displayName: String {
        fileURL?.lastPathComponent ?? "예제 다이어그램"
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Mermaid 파일 열기"
        panel.prompt = "열기"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        var contentTypes: [UTType] = [.plainText, .sourceCode]
        if let mermaidType = UTType(filenameExtension: "mmd") {
            contentTypes.append(mermaidType)
        }
        if let mermaidLongType = UTType(filenameExtension: "mermaid") {
            contentTypes.append(mermaidLongType)
        }
        panel.allowedContentTypes = contentTypes

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        load(url)
    }

    func load(_ url: URL) {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let mermaidSource = MermaidSource.extract(from: contents)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !mermaidSource.isEmpty else {
                throw ReviewCanvasError.emptyDiagram
            }

            source = mermaidSource
            fileURL = url
            loadError = nil
            resetZoom()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reload() {
        guard let fileURL else {
            return
        }
        load(fileURL)
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

    private static let sampleDiagram = """
    flowchart LR
        file[".mmd 파일 열기"] --> render["Mermaid 자동 렌더링"]
        render --> view["다이어그램만 보기"]
    """
}

enum MermaidSource {
    static func extract(from contents: String) -> String {
        let lines = contents.components(separatedBy: .newlines)
        var capturedLines: [String] = []
        var closingFence: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if closingFence == nil {
                if trimmed.lowercased() == "```mermaid" {
                    closingFence = "```"
                    continue
                }
                if trimmed.lowercased() == "~~~mermaid" {
                    closingFence = "~~~"
                    continue
                }
            } else if trimmed.hasPrefix(closingFence!) {
                return capturedLines.joined(separator: "\n")
            } else {
                capturedLines.append(line)
            }
        }

        return contents
    }
}

private enum ReviewCanvasError: LocalizedError {
    case emptyDiagram

    var errorDescription: String? {
        switch self {
        case .emptyDiagram:
            return "파일에 Mermaid 다이어그램이 없습니다."
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
