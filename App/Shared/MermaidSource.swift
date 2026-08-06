import Foundation

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
            } else if let closingFence, trimmed.hasPrefix(closingFence) {
                return capturedLines.joined(separator: "\n")
            } else {
                capturedLines.append(line)
            }
        }

        return contents
    }
}
