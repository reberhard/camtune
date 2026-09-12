import AVFoundation
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.session = session
    }
}

final class CameraPreviewNSView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    var session: AVCaptureSession? {
        didSet {
            guard session !== oldValue else { return }
            setupPreviewLayer()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    private func setupPreviewLayer() {
        previewLayer?.removeFromSuperlayer()
        guard let session else { return }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        // Composition guidance must describe the complete camera image. An
        // aspect-filled preview silently crops edges, which can make it
        // disagree with the frame a video-call app receives.
        layer.videoGravity = .resizeAspect
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        previewLayer = layer
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}
