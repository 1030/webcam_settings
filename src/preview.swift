import AppKit
import AVFoundation
import CoreImage
import Foundation

// Native AVFoundation capture keeps preview identity tied to the same USB port
// used by uvcctl. Frames are length-prefixed JPEGs on stdout; diagnostics use stderr.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("preview: " + message + "\n").utf8))
    exit(1)
}

if CommandLine.arguments.count != 2 {
    fail("usage: preview <AVCaptureDevice uniqueID>")
}

let uniqueID = CommandLine.arguments[1]
guard let camera = AVCaptureDevice(uniqueID: uniqueID) else {
    fail("camera \(uniqueID) is not available")
}

switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized:
    break
case .notDetermined:
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .video) { allowed in
        granted = allowed
        semaphore.signal()
    }
    semaphore.wait()
    if !granted { fail("camera access denied; allow access in System Settings > Privacy & Security > Camera") }
default:
    fail("camera access denied; allow access in System Settings > Privacy & Security > Camera")
}

final class Frames: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var lastFrame = CFAbsoluteTimeGetCurrent()

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFrame < 0.18 { return } // About five frames per second.
        lastFrame = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        let maxDimension = max(image.extent.width, image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: min(1, 720 / maxDimension),
                                                               y: min(1, 720 / maxDimension)))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return }
        let representation = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.78]),
              jpeg.count < 8_000_000 else { return }
        var length = UInt32(jpeg.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(jpeg)
        FileHandle.standardOutput.write(frame)
    }
}

let session = AVCaptureSession()
session.beginConfiguration()
session.sessionPreset = .medium
do {
    let input = try AVCaptureDeviceInput(device: camera)
    guard session.canAddInput(input) else { fail("cannot add camera input") }
    session.addInput(input)
} catch {
    fail("cannot open camera: \(error)")
}
let output = AVCaptureVideoDataOutput()
output.alwaysDiscardsLateVideoFrames = true
let frames = Frames()
output.setSampleBufferDelegate(frames, queue: DispatchQueue(label: "webcam-settings.frames"))
guard session.canAddOutput(output) else { fail("cannot add preview output") }
session.addOutput(output)
session.commitConfiguration()
session.startRunning()
guard session.isRunning else { fail("capture session did not start") }
RunLoop.current.run()
