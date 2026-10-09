import AppKit
import AVFoundation
import CoreImage
import SwiftUI

struct Camera: Decodable, Identifiable, Hashable {
    let name: String
    let id: String
    let location: String
    let serial: String
    var captureID: String {
        let pieces = id.split(separator: ":")
        guard pieces.count == 2,
              let locationNumber = UInt64(location, radix: 16),
              let vendor = UInt64(pieces[0], radix: 16),
              let product = UInt64(pieces[1], radix: 16) else { return "" }
        return String(format: "0x%llx", (locationNumber << 32) | (vendor << 16) | product)
    }
}

struct Preset: Decodable {
    let label: String
    let id: String
    let location: String
}

struct StateResponse: Decodable {
    let cameras: [Camera]
    let presets: [Preset]
}

struct Control: Decodable, Identifiable {
    let name: String
    let label: String
    let group: String
    let kind: String
    let min: Int
    let max: Int
    let step: Int
    let value: Int
    let writable: Bool
    var id: String { name }
}

struct CapsResponse: Decodable {
    let controls: [Control]
}

struct SyncResult: Decodable {
    let location: String
    let ok: Bool
    let errors: [String]
}

struct Sample: Equatable {
    let r: Int
    let g: Int
    let b: Int
    let brightness: Int
}

enum ViewMode: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case exposure = "Exposure false colour"
    var id: String { rawValue }
}

enum CommandRunner {
    static func run(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let resources = Bundle.main.resourceURL else {
                    continuation.resume(throwing: NSError(domain: "WebcamSettings", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "App resources are missing"]))
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [resources.appendingPathComponent("webcam_settings.py").path] + arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: NSError(domain: "WebcamSettings", code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "Camera command failed" : output]))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var cameras: [Camera] = []
    @Published var presets: [Preset] = []
    @Published var selected: String = ""
    @Published var comparison: String = ""
    @Published var controls: [Control] = []
    @Published var label = ""
    @Published var status = "Choose a camera to begin."
    @Published var samples: [String: Sample] = [:]
    @Published var loadingControls = false
    @Published var syncTargets: Set<String> = []
    @Published var syncing = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--camera"), index + 1 < arguments.count {
            selected = arguments[index + 1]
        } else {
            selected = UserDefaults.standard.string(forKey: "selectedCameraPort") ?? ""
        }
    }

    func displayName(_ camera: Camera) -> String {
        presets.first(where: { $0.location == camera.location && $0.id == camera.id })?.label ?? camera.name
    }

    var matchingCameras: [Camera] {
        guard let source = cameras.first(where: { $0.location == selected }) else { return [] }
        return cameras.filter { $0.id == source.id && $0.location != source.location }
    }

    var hasSavedSource: Bool {
        guard let source = cameras.first(where: { $0.location == selected }) else { return false }
        return presets.contains { $0.location == source.location && $0.id == source.id }
    }

    func refresh() async {
        do {
            let result = try await CommandRunner.run(["state"])
            let state = try JSONDecoder().decode(StateResponse.self, from: Data(result.utf8))
            cameras = state.cameras
            presets = state.presets
            if !cameras.contains(where: { $0.location == selected }) {
                selected = cameras.last?.location ?? ""
            }
            syncTargets.formIntersection(Set(matchingCameras.map(\.location)))
            if comparison == selected || !cameras.contains(where: { $0.location == comparison }) {
                comparison = ""
            }
            if let camera = cameras.first(where: { $0.location == selected }) {
                label = presets.first(where: { $0.location == camera.location })?.label ?? ""
                await loadControls()
            } else {
                controls = []
                status = "No UVC cameras connected."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func select(_ location: String) async {
        selected = location
        syncTargets = []
        UserDefaults.standard.set(location, forKey: "selectedCameraPort")
        if comparison == location { comparison = "" }
        label = presets.first(where: { $0.location == location })?.label ?? ""
        samples[location] = nil
        await loadControls()
    }

    func loadControls() async {
        guard !selected.isEmpty else { return }
        let requested = selected
        loadingControls = true
        controls = []
        do {
            let result = try await CommandRunner.run(["inspect", requested])
            guard selected == requested else { return }
            controls = try JSONDecoder().decode(CapsResponse.self, from: Data(result.utf8)).controls
            status = controls.isEmpty ? "This camera is connected, but its UVC controls are not responding." : "Controls ready. Click the preview to sample a skin patch."
        } catch {
            if selected == requested { status = error.localizedDescription }
        }
        loadingControls = false
    }

    func set(_ control: Control, value: Int) async {
        let location = selected
        do {
            let result = try await CommandRunner.run(["set", location, control.name, String(value)])
            guard selected == location else { return }
            let actual = Int(result) ?? value
            if let index = controls.firstIndex(where: { $0.name == control.name }) {
                let old = controls[index]
                controls[index] = Control(name: old.name, label: old.label, group: old.group,
                    kind: old.kind, min: old.min, max: old.max, step: old.step,
                    value: actual, writable: old.writable)
            }
            status = "\(control.label): \(actual)"
        } catch {
            status = error.localizedDescription
        }
    }

    func save() async {
        guard !selected.isEmpty else { return }
        do {
            _ = try await CommandRunner.run(["save", selected, label])
            await refresh()
            status = "Saved preset for \(label.isEmpty ? selected : label)."
        } catch {
            status = error.localizedDescription
        }
    }

    func apply() async {
        do {
            status = "Applying saved presets…"
            let result = try await CommandRunner.run(["apply", "--wait", "30"])
            status = "Presets applied and verified. \(result)"
            await loadControls()
        } catch {
            status = error.localizedDescription
        }
    }

    func sync() async {
        let source = selected
        let targets = syncTargets.sorted()
        guard hasSavedSource, !targets.isEmpty, !syncing else { return }
        syncing = true
        status = "Syncing saved profile to \(targets.count) camera\(targets.count == 1 ? "" : "s")…"
        let output: String
        do {
            output = try await CommandRunner.run(["sync", source] + targets)
        } catch {
            output = error.localizedDescription
        }
        if let results = try? JSONDecoder().decode([SyncResult].self, from: Data(output.utf8)) {
            let summary = results.map { result in
                result.ok ? "Port \(result.location): synced and verified." :
                    "Port \(result.location): \(result.errors.joined(separator: "; "))"
            }.joined(separator: "\n")
            await refresh()
            status = summary
        } else {
            status = output
        }
        syncing = false
    }

    func updateSample(_ sample: Sample, for location: String) {
        samples[location] = sample
    }
}

final class PreviewSurface: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let analysisLayer = CALayer()
    var onClick: ((CGPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        analysisLayer.contentsGravity = .resizeAspect
        analysisLayer.isHidden = true
        layer?.addSublayer(previewLayer)
        layer?.addSublayer(analysisLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        analysisLayer.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 && bounds.height > 0 else { return }
        onClick?(CGPoint(x: min(1, max(0, point.x / bounds.width)),
                         y: min(1, max(0, 1 - point.y / bounds.height))))
    }
}

struct NativePreview: NSViewRepresentable {
    let engine: CaptureEngine
    let mode: ViewMode

    func makeNSView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = engine.session
        view.onClick = { point in engine.setSamplePoint(point) }
        engine.surface = view
        return view
    }

    func updateNSView(_ view: PreviewSurface, context: Context) {
        view.previewLayer.session = engine.session
        view.analysisLayer.isHidden = mode == .normal
        engine.setMode(mode)
        engine.surface = view
    }
}

final class CaptureEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    weak var surface: PreviewSurface?
    var onSample: ((Sample) -> Void)?
    @Published var fps: Double = 0
    @Published var status = "Starting preview…"
    @Published var sample: Sample?
    @Published var resolution = ""

    private let sessionQueue = DispatchQueue(label: "webcam-settings.capture")
    private let framesQueue = DispatchQueue(label: "webcam-settings.frames")
    private let lock = NSLock()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private lazy var colourMap = makeColourMap()
    private var mode: ViewMode = .normal
    private var samplePoint = CGPoint(x: 0.5, y: 0.5)
    private var frameCount = 0
    private var droppedCount = 0
    private var lastRateTime = CFAbsoluteTimeGetCurrent()
    private var running = false
    private var location = ""

    private func debug(_ text: String) {
        guard let path = ProcessInfo.processInfo.environment["WEBCAM_SETTINGS_FPS_LOG"] else { return }
        let line = "\(location) \(text)\n"
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    func setMode(_ newMode: ViewMode) {
        lock.lock(); mode = newMode; lock.unlock()
    }

    func setSamplePoint(_ point: CGPoint) {
        lock.lock(); samplePoint = point; lock.unlock()
    }

    func start(_ camera: Camera) {
        location = camera.location
        DispatchQueue.main.async { self.status = "Starting preview…" }
        let access = AVCaptureDevice.authorizationStatus(for: .video)
        debug("authorization \(access.rawValue)")
        if access == .authorized { configure(camera) }
        else if access == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                if allowed { self.configure(camera) }
                else { DispatchQueue.main.async { self.status = "Camera access denied in macOS Privacy & Security settings." } }
            }
        } else {
            DispatchQueue.main.async { self.status = "Camera access denied in macOS Privacy & Security settings." }
        }
    }

    private func configure(_ camera: Camera) {
        sessionQueue.async {
            guard let device = AVCaptureDevice(uniqueID: camera.captureID) else {
                DispatchQueue.main.async { self.status = "Cannot match this USB port to a capture device." }
                return
            }
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd1280x720) { self.session.sessionPreset = .hd1280x720 }
            else if self.session.canSetSessionPreset(.high) { self.session.sessionPreset = .high }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.status = "Camera input is unavailable." }
                    return
                }
                self.session.addInput(input)
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.status = error.localizedDescription }
                return
            }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            self.debug("pixel format 420v")
            output.setSampleBufferDelegate(self, queue: self.framesQueue)
            if self.session.canAddOutput(output) { self.session.addOutput(output) }

            let maximumWidth = Int(ProcessInfo.processInfo.environment["WEBCAM_SETTINGS_MAX_WIDTH"] ?? "") ?? 1280
            let formats30 = device.formats.filter { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return size.width <= maximumWidth && size.height <= 720 &&
                    format.videoSupportedFrameRateRanges.contains {
                        abs($0.maxFrameRate - 30) < 0.1
                    }
            }
            let chosen = formats30.max { lhs, rhs in
                let a = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                let areaA = Int(a.width) * Int(a.height)
                let areaB = Int(b.width) * Int(b.height)
                if areaA != areaB { return areaA < areaB }
                let preferredA = CMFormatDescriptionGetMediaSubType(lhs.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                let preferredB = CMFormatDescriptionGetMediaSubType(rhs.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                return !preferredA && preferredB
            }
            if let chosen {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = chosen
                    if !device.isAutoVideoFrameRateEnabled {
                        if let rate = chosen.videoSupportedFrameRateRanges.first(where: {
                            abs($0.maxFrameRate - 30) < 0.1
                        }) {
                            device.activeVideoMinFrameDuration = rate.minFrameDuration
                            device.activeVideoMaxFrameDuration = rate.minFrameDuration
                        }
                    }
                    device.unlockForConfiguration()
                    let size = CMVideoFormatDescriptionGetDimensions(chosen.formatDescription)
                    self.debug("capture \(camera.captureID) format=\(size.width)x\(size.height) target=30")
                    DispatchQueue.main.async { self.resolution = "\(size.width)×\(size.height)" }
                } catch {
                    self.debug("30 FPS format rejected: \(error.localizedDescription)")
                }
            } else {
                self.debug("no advertised 30 FPS format at or below 1280x720")
            }
            self.session.commitConfiguration()
            self.debug("actual frame duration \(CMTimeGetSeconds(device.activeVideoMinFrameDuration))")
            self.session.startRunning()
            self.running = self.session.isRunning
            self.debug("session running=\(self.running)")
            DispatchQueue.main.async {
                self.status = self.running ? "Receiving camera frames" : "Capture session did not start."
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if self.fps == 0 && self.running { self.status = "No frames yet. Check this camera or its USB connection." }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.running = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        frameCount += 1
        if now - lastRateTime >= 1 {
            let measured = Double(frameCount) / (now - lastRateTime)
            debug(String(format: "fps %.1f dropped %d", measured, droppedCount))
            frameCount = 0
            droppedCount = 0
            lastRateTime = now
            DispatchQueue.main.async { self.fps = measured }
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); let mode = self.mode; let point = samplePoint; lock.unlock()
        if frameCount % 12 == 0, let value = samplePixelBuffer(buffer, at: point) {
            DispatchQueue.main.async { self.sample = value; self.onSample?(value) }
        }
        if mode == .exposure {
            let input = CIImage(cvPixelBuffer: buffer)
            if let filter = CIFilter(name: "CIColorMap") {
                filter.setValue(input, forKey: kCIInputImageKey)
                filter.setValue(colourMap, forKey: "inputGradientImage")
                if let result = filter.outputImage,
                   let image = ciContext.createCGImage(result, from: result.extent) {
                    DispatchQueue.main.async { self.surface?.analysisLayer.contents = image }
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        droppedCount += 1
    }

    private func samplePixelBuffer(_ buffer: CVPixelBuffer, at point: CGPoint) -> Sample? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let cx = Int(point.x * CGFloat(width)), cy = Int(point.y * CGFloat(height))
        let radius = max(8, min(width, height) / 20)
        var red = 0, green = 0, blue = 0, count = 0
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
           let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
           let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let yPixels = yBase.assumingMemoryBound(to: UInt8.self)
            let uvPixels = uvBase.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for y in Swift.stride(from: max(0, cy-radius), to: min(height, cy+radius), by: 3) {
                for x in Swift.stride(from: max(0, cx-radius), to: min(width, cx+radius), by: 3) {
                    let luma = max(0, Double(yPixels[y*yStride+x])-16) * 1.164
                    let uv = (y/2)*uvStride+(x/2)*2
                    let cb = Double(uvPixels[uv])-128, cr = Double(uvPixels[uv+1])-128
                    red += Int(min(255,max(0,luma+1.793*cr)))
                    green += Int(min(255,max(0,luma-0.213*cb-0.533*cr)))
                    blue += Int(min(255,max(0,luma+2.112*cb)))
                    count += 1
                }
            }
        } else if let base = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in Swift.stride(from: max(0, cy-radius), to: min(height, cy+radius), by: 3) {
                for x in Swift.stride(from: max(0, cx-radius), to: min(width, cx+radius), by: 3) {
                    let index = y * stride + x * 4
                    blue += Int(pixels[index]); green += Int(pixels[index+1]); red += Int(pixels[index+2])
                    count += 1
                }
            }
        }
        guard count > 0 else { return nil }
        let r = red/count, g = green/count, b = blue/count
        return Sample(r: r, g: g, b: b,
            brightness: Int((0.2126*Double(r) + 0.7152*Double(g) + 0.0722*Double(b))/2.55))
    }

    private func makeColourMap() -> CIImage {
        let colours: [[UInt8]] = [[98,67,185],[66,123,211],[67,200,210],
                                  [89,189,98],[240,215,80],[244,155,66],[237,85,85]]
        var bytes = [UInt8]()
        for value in 0..<256 {
            let band = value < 26 ? 0 : value < 51 ? 1 : value < 90 ? 2 :
                       value < 140 ? 3 : value < 190 ? 4 : value < 230 ? 5 : 6
            bytes.append(contentsOf: colours[band] + [255])
        }
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: 256, height: 1, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        return CIImage(cgImage: image)
    }
}

struct VideoPanel: View {
    let camera: Camera
    let mode: ViewMode
    let onSample: (Sample) -> Void
    @StateObject private var engine = CaptureEngine()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativePreview(engine: engine, mode: mode)
                .frame(maxWidth: .infinity, minHeight: 260)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(String(format: "%.1f FPS", engine.fps))
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundStyle(engine.fps >= 27 ? .green : .orange)
                Text("target 30")
                    .foregroundStyle(.secondary)
                if !engine.resolution.isEmpty {
                    Text(engine.resolution).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let sample = engine.sample {
                    Circle().fill(Color(red: Double(sample.r)/255,
                                         green: Double(sample.g)/255,
                                         blue: Double(sample.b)/255))
                        .frame(width: 18, height: 18)
                    Text("\(sample.brightness)% · RGB \(sample.r)/\(sample.g)/\(sample.b)")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            Text(engine.status).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .onAppear { engine.onSample = onSample; engine.start(camera) }
        .onDisappear { engine.stop() }
    }
}

struct ControlRow: View {
    let control: Control
    let setValue: (Int) -> Void
    @State private var sliderValue: Double

    init(control: Control, setValue: @escaping (Int) -> Void) {
        self.control = control
        self.setValue = setValue
        _sliderValue = State(initialValue: Double(control.value))
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(control.label).frame(width: 195, alignment: .leading)
            if control.kind == "range" {
                Slider(value: $sliderValue, in: Double(control.min)...Double(max(control.min+1,control.max)),
                       step: Double(max(1,control.step))) { editing in
                    if !editing { setValue(Int(sliderValue.rounded())) }
                }
                .disabled(!control.writable)
                Text("\(Int(sliderValue))").monospacedDigit().frame(width: 55, alignment: .trailing)
            } else if control.kind == "bool" {
                Toggle("", isOn: Binding(get: { sliderValue != 0 }, set: { newValue in
                    sliderValue = newValue ? 1 : 0
                    setValue(Int(sliderValue))
                })).labelsHidden().disabled(!control.writable)
                Spacer()
            } else {
                Picker("", selection: Binding(get: { Int(sliderValue) }, set: { newValue in
                    sliderValue = Double(newValue); setValue(newValue)
                })) {
                    ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
                }
                .labelsHidden().frame(maxWidth: 200).disabled(!control.writable)
                Spacer()
            }
        }
        .onChange(of: control.value) { _, newValue in sliderValue = Double(newValue) }
    }

    private var options: [(Int,String)] {
        if control.name == "exposure_auto" {
            return [(1,"Manual"),(2,"Auto"),(4,"Shutter priority"),(8,"Aperture priority")]
                .filter { $0.0 == control.value || control.step & $0.0 != 0 }
        }
        if control.name == "power_line_frequency" {
            return [(0,"Off"),(1,"50 Hz"),(2,"60 Hz"),(3,"Auto")]
        }
        return [(control.value,String(control.value))]
    }
}

struct MainView: View {
    @StateObject private var model = AppModel()
    @State private var mode: ViewMode = ProcessInfo.processInfo.arguments.contains("--mode=exposure") ? .exposure : .normal

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView { content.padding(24).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .frame(minWidth: 1080, minHeight: 780)
        .task { await model.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cameras").font(.title2.bold())
            ForEach(model.cameras, id: \.location) { cam in
                Button { Task { await model.select(cam.location) } } label: {
                    VStack(alignment: .leading) {
                        Text(model.displayName(cam)).fontWeight(.semibold)
                        Text("USB port \(cam.location)").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(model.selected == cam.location ? Color.accentColor.opacity(0.22) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Button("Refresh cameras") { Task { await model.refresh() } }
            Spacer()
            Text("OBS restore command").font(.headline)
            Text("webcam-settings apply --wait 30")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("The installed agent also restores presets when OBS starts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 235)
    }

    @ViewBuilder private var content: some View {
        if let selected = model.cameras.first(where: { $0.location == model.selected }) {
            VStack(alignment: .leading, spacing: 20) {
                previewSection(selected)
                presetSection
                Divider()
                controlsSection
            }
        } else {
            Text("Connect a UVC camera, then refresh.").font(.title2)
        }
    }

    private func previewSection(_ camera: Camera) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.displayName(camera)).font(.largeTitle.bold())
                Spacer()
                Picker("Compare with", selection: $model.comparison) {
                    Text("None").tag("")
                    ForEach(model.cameras.filter { $0.location != camera.location }, id: \.location) { other in
                        Text(model.displayName(other) + " · " + other.location).tag(other.location)
                    }
                }.frame(width: 300)
                Picker("View", selection: $mode) {
                    ForEach(ViewMode.allCases) { value in Text(value.rawValue).tag(value) }
                }.frame(width: 210)
            }
            HStack(alignment: .top, spacing: 16) {
                VideoPanel(camera: camera, mode: mode) { sample in
                    model.updateSample(sample, for: camera.location)
                }.id(camera.location)
                if let other = model.cameras.first(where: { $0.location == model.comparison }) {
                    VideoPanel(camera: other, mode: mode) { sample in
                        model.updateSample(sample, for: other.location)
                    }.id(other.location)
                }
            }.frame(height: 350)
            if mode == .exposure { exposureLegend }
            if let first = model.samples[camera.location],
               let second = model.samples[model.comparison] {
                Text("Comparison minus primary: brightness \(second.brightness-first.brightness) points · RGB \(second.r-first.r) / \(second.g-first.g) / \(second.b-first.b)")
                    .font(.system(.subheadline, design: .monospaced))
            }
            Text("Click the same skin patch in each image. Measured FPS is the incoming camera rate; OBS configures its own source rate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var exposureLegend: some View {
        let labels = ["0–10","10–20","20–35","35–55","55–75","75–90","90–100"]
        let colors: [Color] = [.purple,.blue,.cyan,.green,.yellow,.orange,.red]
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                Text(labels[index]).frame(maxWidth: .infinity)
                    .padding(5).background(colors[index]).foregroundStyle(.black)
            }
        }.font(.caption)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Camera position, e.g. Wide shot", text: $model.label)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Button("Save preset") { Task { await model.save() } }
                Button("Apply all presets") { Task { await model.apply() } }
            }
            GroupBox("Sync saved profile parameters") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Copy this camera’s saved control values to selected cameras of the same model. Each target keeps its own name and USB port binding.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.hasSavedSource {
                        Text("Save this camera before syncing.").font(.caption).foregroundStyle(.secondary)
                    } else if model.matchingCameras.isEmpty {
                        Text("No other connected cameras of this model.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.matchingCameras, id: \.location) { camera in
                            Toggle(isOn: Binding(
                                get: { model.syncTargets.contains(camera.location) },
                                set: { selected in
                                    if selected { model.syncTargets.insert(camera.location) }
                                    else { model.syncTargets.remove(camera.location) }
                                }
                            )) {
                                Text("\(model.displayName(camera)) · USB port \(camera.location)")
                            }
                            .disabled(model.syncing)
                        }
                    }
                    Button(model.syncing ? "Syncing…" : "Sync to selected cameras") {
                        Task { await model.sync() }
                    }
                    .disabled(!model.hasSavedSource || model.syncTargets.isEmpty || model.syncing)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(model.status).font(.caption).textSelection(.enabled)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera controls").font(.title2.bold())
            if model.loadingControls { ProgressView("Reading controls…") }
            if model.controls.isEmpty && !model.loadingControls {
                Text("No readable UVC controls for this camera.").foregroundStyle(.secondary)
            }
            ForEach(["color","image","exposure","lens","privacy"], id: \.self) { group in
                let controls = model.controls.filter { $0.group == group }
                if !controls.isEmpty {
                    GroupBox(group.capitalized) {
                        VStack(spacing: 12) {
                            ForEach(controls) { control in
                                ControlRow(control: control) { value in
                                    Task { await model.set(control, value: value) }
                                }
                            }
                        }.padding(8)
                    }
                }
            }
        }
    }
}

@main struct WebcamSettingsApp: App {
    var body: some Scene {
        WindowGroup("Webcam Settings") { MainView() }
    }
}
