import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Vision

@MainActor
final class CameraCaptureService {
    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var videoDelegate: VideoFrameDelegate?
    private var device: AVCaptureDevice?
    var sceneHandler: ((SceneMetrics) -> Void)?

    /// Find an external USB camera (e.g. Brio), falling back to built-in.
    nonisolated static func findCamera(named name: String? = nil) -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        let devices = discovery.devices

        if let name {
            let matches = devices.filter { $0.localizedName.localizedCaseInsensitiveContains(name) }
            return matches.count == 1 ? matches[0] : nil
        }
        // Prefer external cameras over built-in
        return devices.first { $0.deviceType == .external } ?? devices.first
    }

    /// Create and start a capture session for live preview + photo capture.
    func startSession(device: AVCaptureDevice) throws -> AVCaptureSession {
        if let existing = session {
            return existing
        }

        let newSession = AVCaptureSession()
        newSession.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard newSession.canAddInput(input) else {
            throw CaptureError.setupFailed("Cannot add camera input")
        }
        newSession.addInput(input)

        let output = AVCapturePhotoOutput()
        guard newSession.canAddOutput(output) else {
            throw CaptureError.setupFailed("Cannot add photo output")
        }
        newSession.addOutput(output)

        let frameOutput = AVCaptureVideoDataOutput()
        frameOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        frameOutput.alwaysDiscardsLateVideoFrames = true
        let delegate = VideoFrameDelegate { [weak self] scene in
            Task { @MainActor in
                self?.sceneHandler?(scene)
            }
        }
        if newSession.canAddOutput(frameOutput) {
            frameOutput.setSampleBufferDelegate(
                delegate,
                queue: DispatchQueue(label: "ojo.preview.vision")
            )
            newSession.addOutput(frameOutput)
            if let connection = frameOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            self.videoOutput = frameOutput
            self.videoDelegate = delegate
        }

        self.session = newSession
        self.photoOutput = output
        self.device = device

        newSession.startRunning()
        return newSession
    }

    func stopSession() {
        session?.stopRunning()
        session = nil
        photoOutput = nil
        videoOutput = nil
        videoDelegate = nil
        device = nil
    }

    /// Capture a single JPEG frame for analysis.
    func capturePhoto(maxWidth: Int = 1600, quality: Double = 0.85) async throws -> Data {
        guard let output = photoOutput, let device else {
            throw CaptureError.notRunning
        }

        // Wait for exposure/WB to settle
        await waitForAutoAdjustments(device: device)

        let rawData: Data = try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoDelegate(continuation: continuation)
            let settings = AVCapturePhotoSettings()
            if let codec = output.availablePhotoCodecTypes.first(where: { $0 == .jpeg }) {
                let _ = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                // Use default settings for simplicity
            }
            output.capturePhoto(with: settings, delegate: delegate)
            // Keep delegate alive until callback
            _retainedDelegate = delegate
        }
        _retainedDelegate = nil

        return try transcodeJPEG(rawData, maxWidth: maxWidth, quality: quality)
    }

    private var _retainedDelegate: PhotoDelegate?

    private func waitForAutoAdjustments(device: AVCaptureDevice) async {
        let maxSteps = 30 // ~1.5s
        for _ in 0..<maxSteps {
            if !device.isAdjustingExposure && !device.isAdjustingWhiteBalance {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func transcodeJPEG(_ data: Data, maxWidth: Int, quality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return data // Return original if transcoding fails
        }

        let originalWidth = cgImage.width
        let originalHeight = cgImage.height

        let scale: CGFloat
        if originalWidth > maxWidth {
            scale = CGFloat(maxWidth) / CGFloat(originalWidth)
        } else {
            scale = 1.0
        }

        let newWidth = Int(CGFloat(originalWidth) * scale)
        let newHeight = Int(CGFloat(originalHeight) * scale)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return data }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let resized = context.makeImage() else { return data }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return data }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, resized, options as CFDictionary)
        CGImageDestinationFinalize(dest)

        return mutableData as Data
    }

    enum CaptureError: LocalizedError {
        case setupFailed(String)
        case notRunning
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .setupFailed(let msg): return "Camera setup failed: \(msg)"
            case .notRunning: return "Camera session is not running"
            case .captureFailed(let msg): return "Photo capture failed: \(msg)"
            }
        }
    }
}

/// Delegate that bridges AVCapturePhotoCaptureDelegate to async/await.
private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, Error>

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            continuation.resume(throwing: CameraCaptureService.CaptureError.captureFailed(
                error.localizedDescription))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: CameraCaptureService.CaptureError.captureFailed(
                "No data in photo"))
            return
        }
        continuation.resume(returning: data)
    }
}

private final class VideoFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let handler: @Sendable (SceneMetrics) -> Void
    private var lastProcessed = Date.distantPast

    init(handler: @escaping @Sendable (SceneMetrics) -> Void) { self.handler = handler }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) > 0.5 else { return }
        lastProcessed = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            handler(SceneMetrics(faceBox: nil, faceCount: nil, measuredAt: now)); return
        }
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
            let faces = request.results ?? []
            guard faces.count == 1, let face = faces.first else {
                handler(SceneMetrics(faceBox: nil, faceCount: faces.count, measuredAt: now)); return
            }
            let box = face.boundingBox
            let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            var scene = SceneMetrics(faceBox: rect, faceCount: 1, measuredAt: now)
            scene.photometry = Self.photometry(pixelBuffer, faceBox: rect)
            handler(scene)
        } catch {
            handler(SceneMetrics(faceBox: nil, faceCount: nil, measuredAt: now))
        }
    }

    static func photometry(_ buffer: CVPixelBuffer, faceBox: CGRect) -> [String: Double] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return [:] }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let strideBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var face: [Double] = [], bg: [Double] = []
        var red = 0.0, green = 0.0, blue = 0.0
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let offset = y * strideBytes + x * 4
                let b = Double(bytes[offset]), g = Double(bytes[offset + 1]), r = Double(bytes[offset + 2])
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if faceBox.contains(CGPoint(x: Double(x) / Double(width), y: Double(y) / Double(height))) {
                    face.append(luma); red += r; green += g; blue += b
                } else { bg.append(luma) }
            }
        }
        guard !face.isEmpty, !bg.isEmpty else { return [:] }
        face.sort()
        let n = Double(face.count), avg = (red + green + blue) / 3
        var result = [
            "face_luma_mean": face.reduce(0, +) / n,
            "face_luma_p05": face[Int(Double(face.count - 1) * 0.05)],
            "face_luma_p95": face[Int(Double(face.count - 1) * 0.95)],
            "background_luma_mean": bg.reduce(0, +) / Double(bg.count),
            "highlight_clip_pct": Double(face.filter { $0 >= 245 }.count) / n * 100,
            "shadow_clip_pct": Double(face.filter { $0 <= 10 }.count) / n * 100,
        ]
        if avg > 0 { result["red_balance"] = red / avg; result["green_balance"] = green / avg; result["blue_balance"] = blue / avg }
        return result
    }
}
