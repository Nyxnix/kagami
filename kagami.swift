// kagami (鏡) — OBS-style capture-card preview.
// Video: native-format frames → AVSampleBufferDisplayLayer with display-immediately
//   (GPU handles pixel format, latest frame wins, no player clock).
// Audio: AVCaptureAudioDataOutput (own session, Float32) → AVAudioPlayerNode (~20-40ms).
// UI: mpv-style auto-hiding overlay with volume slider + resolution/framerate pickers.
// Build: swiftc -O -o ~/.local/bin/kagami ~/kagami/kagami.swift
import AVFoundation
import AppKit

let NAME = "Live Gamer"

let session = AVCaptureSession()

let cam: AVCaptureDevice = {
    guard let c = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.first(where: { $0.localizedName.contains(NAME) }) else {
        fputs("capture: no video device matching \"\(NAME)\"\n", stderr)
        exit(1)
    }
    return c
}()
session.addInput(try! AVCaptureDeviceInput(device: cam))

// ---------- modes offered by the card ----------
struct Mode: Equatable { let w: Int32; let h: Int32 }
let modes: [Mode] = {
    var seen = [Mode]()
    for f in cam.formats {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let m = Mode(w: d.width, h: d.height)
        if !seen.contains(m) { seen.append(m) }
    }
    return seen.sorted { Int($0.w) * Int($0.h) > Int($1.w) * Int($1.h) }
}()
func rates(for m: Mode) -> [Double] {
    var out = [Double]()
    for f in cam.formats {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        guard d.width == m.w && d.height == m.h else { continue }
        for r in f.videoSupportedFrameRateRanges where !out.contains(where: { abs($0 - r.maxFrameRate) < 0.01 }) {
            out.append(r.maxFrameRate)
        }
    }
    return out.sorted(by: >)
}

var expectedFPS = 60.0   // drop-warning threshold tracks the selected rate
let vivid = !CommandLine.arguments.contains("--accurate")

// Must run AFTER startRunning: the session renegotiates the device format on start.
func applyMode(_ m: Mode, fps: Double) {
    guard let fmt = cam.formats.first(where: { f in
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return d.width == m.w && d.height == m.h
            && f.videoSupportedFrameRateRanges.contains { abs($0.maxFrameRate - fps) < 0.01 }
    }), let range = fmt.videoSupportedFrameRateRanges.first(where: { abs($0.maxFrameRate - fps) < 0.01 })
    else { return }
    try? cam.lockForConfiguration()
    cam.activeFormat = fmt
    cam.activeVideoMinFrameDuration = range.minFrameDuration
    cam.activeVideoMaxFrameDuration = range.minFrameDuration
    cam.unlockForConfiguration()
    expectedFPS = fps
    displayLayer.flush()   // dimension change mid-stream stalls the layer otherwise
}

// ---------- video ----------
let displayLayer = AVSampleBufferDisplayLayer()
displayLayer.videoGravity = .resizeAspect
displayLayer.backgroundColor = NSColor.black.cgColor

final class VideoFeeder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let layer: AVSampleBufferDisplayLayer
    var frames = 0, enqueued = 0, refused = 0, flushes = 0
    var lastReport = CFAbsoluteTimeGetCurrent()
    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        frames += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastReport >= 5 {
            let fps = Double(frames) / (now - lastReport)
            fputs(String(format: "capture-stats: fps=%.0f enq=%d refused=%d flushes=%d status=%d needsFlush=%d\n",
                         fps, enqueued, refused, flushes, layer.status.rawValue,
                         layer.requiresFlushToResumeDecoding ? 1 : 0), stderr)
            frames = 0; enqueued = 0; refused = 0; flushes = 0; lastReport = now
        }
        // vivid (default): tag frames P3 so the compositor skips gamut mapping —
        // matches the punch of direct HDMI / OBS's unmanaged preview on this panel.
        // --accurate keeps the card's BT.709 tags (color-managed, technically correct).
        if vivid, let pb = CMSampleBufferGetImageBuffer(sb) {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
            CVBufferRemoveAttachment(pb, kCVImageBufferCGColorSpaceKey)
        }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush(); flushes += 1 }
        if layer.isReadyForMoreMediaData {
            layer.enqueue(sb); enqueued += 1
        } else {
            // layer wedged with a full queue: dump it and retry — latest frame wins
            layer.flush(); flushes += 1
            if layer.isReadyForMoreMediaData { layer.enqueue(sb); enqueued += 1 } else { refused += 1 }
        }
    }
}

let videoFeeder = VideoFeeder(layer: displayLayer)
let videoOut = AVCaptureVideoDataOutput()   // no videoSettings: native format, zero conversion
videoOut.alwaysDiscardsLateVideoFrames = true
videoOut.setSampleBufferDelegate(videoFeeder, queue: DispatchQueue(label: "capture.video"))
guard session.canAddOutput(videoOut) else { fputs("capture: cannot add video output\n", stderr); exit(1) }
session.addOutput(videoOut)

// ---------- audio ----------
final class AudioFeeder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    var format: AVAudioFormat?
    var stdFormat: AVAudioFormat?
    var converter: AVAudioConverter?
    var scheduledFrames: AVAudioFramePosition = 0
    var lastLoud = CFAbsoluteTimeGetCurrent()
    var lastSilenceNote = CFAbsoluteTimeGetCurrent()
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sb) else { return }
        let numFrames = CMSampleBufferGetNumSamples(sb)
        if format == nil {
            let f = AVAudioFormat(cmAudioFormatDescription: desc)
            guard let std = AVAudioFormat(standardFormatWithSampleRate: f.sampleRate,
                                          channels: f.channelCount),
                  let conv = AVAudioConverter(from: f, to: std) else {
                fputs("capture: no converter for \(f), video only\n", stderr); return
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: std)
            do { try engine.start(); player.play() }
            catch { fputs("capture: audio engine failed (\(error)), video only\n", stderr); return }
            format = f; stdFormat = std; converter = conv
        }
        guard let f = format, let std = stdFormat, let conv = converter, numFrames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(numFrames)),
              let out = AVAudioPCMBuffer(pcmFormat: std, frameCapacity: AVAudioFrameCount(numFrames)) else { return }
        pcm.frameLength = AVAudioFrameCount(numFrames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(numFrames),
                into: pcm.mutableAudioBufferList) == noErr else { return }
        do { try conv.convert(to: out, from: pcm) } catch { return }
        if let fl = out.floatChannelData {
            for i in 0..<Int(out.frameLength) where abs(fl[0][i]) > 0.001 { lastLoud = CFAbsoluteTimeGetCurrent(); break }
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLoud > 10 && now - lastSilenceNote > 10 {
            fputs("capture: card audio is silent for 10s (source muted or asleep?)\n", stderr)
            lastSilenceNote = now
        }
        // ponytail: if the card's clock outruns the output's, drop buffers past 100ms of
        // backlog; proper fix is rate-matching resample if drift ever gets audible
        if let rt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: rt),
           scheduledFrames - pt.sampleTime > AVAudioFramePosition(f.sampleRate / 10) {
            return
        }
        scheduledFrames += AVAudioFramePosition(numFrames)
        player.scheduleBuffer(out, completionHandler: nil)
    }
}

// separate session: sharing one session with video delivers all-zero audio samples
// through AVCaptureAudioDataOutput (audio-only sessions work; ffmpeg does the same)
let audioSession = AVCaptureSession()
let audioFeeder = AudioFeeder()
if let mic = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        .devices.first(where: { $0.localizedName.contains(NAME) }) {
    audioSession.addInput(try! AVCaptureDeviceInput(device: mic))
    let audioOut = AVCaptureAudioDataOutput()
    audioOut.audioSettings = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    audioOut.setSampleBufferDelegate(audioFeeder, queue: DispatchQueue(label: "capture.audio"))
    if audioSession.canAddOutput(audioOut) { audioSession.addOutput(audioOut) }
    audioSession.startRunning()
} else {
    fputs("capture: card audio not found, video only\n", stderr)
}

// ---------- overlay controls (mpv-style OSC: fades in on mouse move, out after idle) ----------
func fpsLabel(_ v: Double) -> String {
    abs(v - v.rounded()) < 0.005 ? String(format: "%.0f fps", v) : String(format: "%.2f fps", v)
}

final class Controls: NSObject {
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 44))
    let volume = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let resPopup = NSPopUpButton(frame: NSRect(x: 190, y: 9, width: 150, height: 26), pullsDown: false)
    let fpsPopup = NSPopUpButton(frame: NSRect(x: 348, y: 9, width: 110, height: 26), pullsDown: false)
    var hideTimer: Timer?

    override init() {
        super.init()
        box.wantsLayer = true
        box.layer!.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        box.layer!.cornerRadius = 8
        box.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]

        volume.frame = NSRect(x: 14, y: 12, width: 160, height: 20)
        volume.target = self
        volume.action = #selector(volumeChanged(_:))
        box.addSubview(volume)

        resPopup.addItems(withTitles: modes.map { "\($0.w)×\($0.h)" })
        resPopup.target = self
        resPopup.action = #selector(resChanged(_:))
        box.addSubview(resPopup)

        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged(_:))
        box.addSubview(fpsPopup)
    }

    var currentMode: Mode { modes[max(0, resPopup.indexOfSelectedItem)] }

    func select(mode: Mode, fps: Double) {
        if let i = modes.firstIndex(of: mode) { resPopup.selectItem(at: i) }
        fpsPopup.removeAllItems()
        fpsPopup.addItems(withTitles: rates(for: mode).map(fpsLabel))
        if let i = rates(for: mode).firstIndex(where: { abs($0 - fps) < 0.01 }) { fpsPopup.selectItem(at: i) }
    }

    @objc func volumeChanged(_ s: NSSlider) {
        audioFeeder.engine.mainMixerNode.outputVolume = Float(s.doubleValue / 100)
        poke()
    }
    @objc func resChanged(_ s: NSPopUpButton) {
        let m = currentMode
        let best = rates(for: m).first ?? 60
        select(mode: m, fps: best)
        applyMode(m, fps: best)
        poke()
    }
    @objc func fpsChanged(_ s: NSPopUpButton) {
        let m = currentMode
        let r = rates(for: m)
        let idx = max(0, s.indexOfSelectedItem)
        if idx < r.count { applyMode(m, fps: r[idx]) }
        poke()
    }

    func poke() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            box.animator().alphaValue = 1
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            // mpv behavior: stay visible while the cursor is parked on the controls
            if let w = self.box.window {
                let p = self.box.convert(w.mouseLocationOutsideOfEventStream, from: nil)
                if self.box.bounds.contains(p) { self.poke(); return }
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.box.animator().alphaValue = 0
            }
        }
    }
}

final class TrackingView: NSView {
    var onMove: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseMoved(with e: NSEvent) { onMove?() }
    override func mouseEntered(with e: NSEvent) { onMove?() }
}

// ---------- window ----------
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let view = TrackingView()
view.layer = displayLayer
view.wantsLayer = true

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
window.title = "kagami"
window.contentView = view
window.acceptsMouseMovedEvents = true
window.center()
window.makeKeyAndOrderFront(nil)

let controls = Controls()
controls.box.frame.origin = NSPoint(x: (view.bounds.width - controls.box.frame.width) / 2, y: 16)
view.addSubview(controls.box)
view.onMove = { controls.poke() }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
let delegate = AppDelegate()
app.delegate = delegate

// minimal main menu so ⌘Q (and ⌘W) work
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
appMenu.addItem(NSMenuItem(title: "Quit kagami", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

session.startRunning()
let startMode = modes.first(where: { $0.w == 2560 && $0.h == 1440 }) ?? modes.first ?? Mode(w: 1920, h: 1080)
let startFPS = rates(for: startMode).first ?? 60
applyMode(startMode, fps: startFPS)
controls.select(mode: startMode, fps: startFPS)
controls.poke()   // show briefly at launch, then fade
app.activate()
app.run()
