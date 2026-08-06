import Foundation

public struct NormalizedPoint: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public static let zero = NormalizedPoint(uncheckedX: 0, y: 0)
    public static let center = NormalizedPoint(uncheckedX: 0.5, y: 0.5)
    public static let topRight = NormalizedPoint(uncheckedX: 1, y: 0)

    public init(x: Double, y: Double) throws {
        guard x.isFinite, (0...1).contains(x) else {
            throw ReviewCanvasError.invalidNormalizedCoordinate(axis: .x, value: x)
        }
        guard y.isFinite, (0...1).contains(y) else {
            throw ReviewCanvasError.invalidNormalizedCoordinate(axis: .y, value: y)
        }

        self.x = x
        self.y = y
    }

    private init(uncheckedX x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }
}

public struct NodeAnchor: Codable, Hashable, Sendable {
    public let nodeID: String
    public let position: NormalizedPoint

    public init(nodeID: String, position: NormalizedPoint) throws {
        let normalizedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw ReviewCanvasError.emptyAnchorIdentifier(.node)
        }

        self.nodeID = normalizedID
        self.position = position
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nodeID: container.decode(String.self, forKey: .nodeID),
            position: container.decode(NormalizedPoint.self, forKey: .position)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case nodeID
        case position
    }
}

public struct EdgeAnchor: Codable, Hashable, Sendable {
    public let edgeID: String
    public let position: NormalizedPoint

    public init(edgeID: String, position: NormalizedPoint) throws {
        let normalizedID = edgeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw ReviewCanvasError.emptyAnchorIdentifier(.edge)
        }

        self.edgeID = normalizedID
        self.position = position
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            edgeID: container.decode(String.self, forKey: .edgeID),
            position: container.decode(NormalizedPoint.self, forKey: .position)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case edgeID
        case position
    }
}

public struct CanvasAnchor: Codable, Hashable, Sendable {
    public let position: NormalizedPoint

    public init(position: NormalizedPoint) {
        self.position = position
    }
}

public enum DiagramAnchor: Hashable, Sendable {
    case node(NodeAnchor)
    case edge(EdgeAnchor)
    case canvas(CanvasAnchor)

    public static func node(nodeID: String, position: NormalizedPoint) throws -> Self {
        .node(try NodeAnchor(nodeID: nodeID, position: position))
    }

    public static func edge(edgeID: String, position: NormalizedPoint) throws -> Self {
        .edge(try EdgeAnchor(edgeID: edgeID, position: position))
    }

    public static func canvas(position: NormalizedPoint) -> Self {
        .canvas(CanvasAnchor(position: position))
    }

    public var kind: AnchorKind {
        switch self {
        case .node:
            .node
        case .edge:
            .edge
        case .canvas:
            .canvas
        }
    }

    public var position: NormalizedPoint {
        switch self {
        case let .node(anchor):
            anchor.position
        case let .edge(anchor):
            anchor.position
        case let .canvas(anchor):
            anchor.position
        }
    }

    public var targetID: String? {
        switch self {
        case let .node(anchor):
            anchor.nodeID
        case let .edge(anchor):
            anchor.edgeID
        case .canvas:
            nil
        }
    }
}

extension DiagramAnchor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(AnchorKind.self, forKey: .kind)
        let position = try container.decode(NormalizedPoint.self, forKey: .position)

        switch kind {
        case .node:
            self = try .node(
                nodeID: container.decode(String.self, forKey: .nodeID),
                position: position
            )
        case .edge:
            self = try .edge(
                edgeID: container.decode(String.self, forKey: .edgeID),
                position: position
            )
        case .canvas:
            self = .canvas(position: position)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(position, forKey: .position)

        switch self {
        case let .node(anchor):
            try container.encode(anchor.nodeID, forKey: .nodeID)
        case let .edge(anchor):
            try container.encode(anchor.edgeID, forKey: .edgeID)
        case .canvas:
            break
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case nodeID
        case edgeID
        case position
    }
}
