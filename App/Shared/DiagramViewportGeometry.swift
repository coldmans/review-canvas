import CoreGraphics

struct DiagramViewportGeometry: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var nodes: [DiagramNodeGeometry] = []

    static let unavailable = DiagramViewportGeometry(x: 0, y: 0, width: 0, height: 0)

    var isAvailable: Bool {
        width > 0 && height > 0
    }

    func location(forNormalizedX normalizedX: Double, y normalizedY: Double, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (x + normalizedX * width) * size.width,
            y: (y + normalizedY * height) * size.height
        )
    }

    func normalizedPoint(for location: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0, width > 0, height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let viewportX = Double(location.x / size.width)
        let viewportY = Double(location.y / size.height)
        return CGPoint(
            x: min(1, max(0, (viewportX - x) / width)),
            y: min(1, max(0, (viewportY - y) / height))
        )
    }

    func contains(_ location: CGPoint, in size: CGSize) -> Bool {
        guard isAvailable, size.width > 0, size.height > 0 else {
            return false
        }

        let viewportX = Double(location.x / size.width)
        let viewportY = Double(location.y / size.height)
        return viewportX >= x
            && viewportX <= x + width
            && viewportY >= y
            && viewportY <= y + height
    }

    func nodeID(at normalizedPoint: CGPoint) -> String? {
        let matchingNode = nodes
            .filter { $0.contains(normalizedPoint) }
            .min { $0.area < $1.area }

        return matchingNode?.id
    }
}

struct DiagramNodeGeometry: Equatable, Sendable {
    let id: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var area: Double {
        width * height
    }

    func contains(_ point: CGPoint) -> Bool {
        let pointX = Double(point.x)
        let pointY = Double(point.y)
        return pointX >= x && pointX <= x + width && pointY >= y && pointY <= y + height
    }
}
