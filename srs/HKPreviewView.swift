import SwiftUI
import MetalKit

struct HKPreviewView: UIViewRepresentable {
    let stream: RTMPStream

    func makeUIView(context: Context) -> MTHKView {
        let v = MTHKView(frame: .zero)
        v.videoGravity = .resizeAspectFill
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.preferredFramesPerSecond = 30

        // 记录首帧耗时（可选）
        context.coordinator.startTime = CFAbsoluteTimeGetCurrent()
        v.delegate = context.coordinator

        Task { await stream.addOutput(v) }
        return v
    }

    func updateUIView(_ uiView: MTHKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        var startTime: CFAbsoluteTime?
        private var logged = false

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard !logged else { return }
            logged = true
            if let t0 = startTime {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                print("🎬 首帧出画: \(String(format: "%.1f", ms)) ms")
            }
        }
    }
}

