import Foundation
import ReviewCanvasCore

enum ReviewCanvasWireError: Error, Equatable, LocalizedError {
    case emptyMessage
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyMessage:
            "빈 동기화 메시지는 처리할 수 없습니다."
        case .messageTooLarge:
            "동기화 메시지가 허용 크기를 초과했습니다."
        }
    }
}

enum ReviewCanvasWireCodec {
    static let maximumMessageBytes = 8 * 1_024 * 1_024

    static func encode(_ envelope: PeerSyncEnvelope) throws -> Data {
        let encoder = ReviewCanvasDateCoding.makeEncoder()
        let data = try encoder.encode(envelope)
        guard data.count <= maximumMessageBytes else {
            throw ReviewCanvasWireError.messageTooLarge
        }
        return data
    }

    static func decode(_ data: Data) throws -> PeerSyncEnvelope {
        guard !data.isEmpty else {
            throw ReviewCanvasWireError.emptyMessage
        }
        guard data.count <= maximumMessageBytes else {
            throw ReviewCanvasWireError.messageTooLarge
        }
        return try ReviewCanvasDateCoding.makeDecoder().decode(PeerSyncEnvelope.self, from: data)
    }
}
