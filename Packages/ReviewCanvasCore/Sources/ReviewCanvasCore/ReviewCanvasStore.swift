public actor ReviewCanvasStore {
    private var document: DiagramDocument

    public init(document: DiagramDocument) {
        self.document = document
    }

    public func snapshot() -> DiagramDocument {
        document
    }

    @discardableResult
    public func send(_ action: ReviewCanvasAction) throws -> DiagramDocument {
        try ReviewCanvasReducer.reduce(&document, action: action)
        return document
    }
}
