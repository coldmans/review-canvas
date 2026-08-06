import PencilKit
import SwiftUI

struct PencilCanvasView: UIViewRepresentable {
    @Binding var drawingData: Data
    let isDrawingEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(drawingData: $drawingData)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.delegate = context.coordinator
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .systemOrange, width: 4)
        canvasView.alwaysBounceHorizontal = false
        canvasView.alwaysBounceVertical = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1

        context.coordinator.canvasView = canvasView
        context.coordinator.apply(drawingData, to: canvasView)
        context.coordinator.setDrawingEnabled(isDrawingEnabled, for: canvasView)
        return canvasView
    }

    func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        context.coordinator.drawingData = $drawingData
        context.coordinator.apply(drawingData, to: canvasView)
        context.coordinator.setDrawingEnabled(isDrawingEnabled, for: canvasView)
    }

    static func dismantleUIView(_ canvasView: PKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.removeObserver(canvasView)
        canvasView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawingData: Binding<Data>
        weak var canvasView: PKCanvasView?
        let toolPicker = PKToolPicker()
        private var isApplyingExternalDrawing = false

        init(drawingData: Binding<Data>) {
            self.drawingData = drawingData
        }

        func apply(_ data: Data, to canvasView: PKCanvasView) {
            let currentData = canvasView.drawing.dataRepresentation()
            guard currentData != data else {
                return
            }

            isApplyingExternalDrawing = true
            defer { isApplyingExternalDrawing = false }
            canvasView.drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
        }

        func setDrawingEnabled(_ enabled: Bool, for canvasView: PKCanvasView) {
            canvasView.isUserInteractionEnabled = enabled

            if enabled {
                toolPicker.addObserver(canvasView)
                toolPicker.setVisible(true, forFirstResponder: canvasView)
                canvasView.becomeFirstResponder()
            } else {
                toolPicker.setVisible(false, forFirstResponder: canvasView)
                canvasView.resignFirstResponder()
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing else {
                return
            }
            drawingData.wrappedValue = canvasView.drawing.dataRepresentation()
        }
    }
}
