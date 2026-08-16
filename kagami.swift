// kagami (鏡) — OBS-style capture-card preview.
// Video: native-format frames → AVSampleBufferDisplayLayer with display-immediately
//   (GPU handles pixel format, latest frame wins, no player clock).
// Audio: AVCaptureAudioDataOutput (own session, Float32) → AVAudioPlayerNode (~20-40ms).
// UI: mpv-style auto-hiding overlay (volume, resolution, framerate) + Settings (⌘,)
//   with device pickers, color mode, and always-on-top. Choices persist in UserDefaults.
// Build: ./build.sh
import AVFoundation
import AppKit

let ud = UserDefaults.standard

// ---------- device discovery ----------
func videoDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external, .continuityCamera, .builtInWideAngleCamera],
        mediaType: .video, position: .unspecified).devices
}
func audioDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        // transient CoreAudio-internal aggregates, not real inputs
        .filter { !$0.localizedName.hasPrefix("CADefaultDeviceAggregate") }
}

var cam: AVCaptureDevice = {
    let devs = videoDevices()
    if let uid = ud.string(forKey: "videoUID"), let d = devs.first(where: { $0.uniqueID == uid }) { return d }
    if let d = devs.first(where: { !$0.uniqueID.hasPrefix("com.apple") && $0.localizedName.range(of: "camera", options: .caseInsensitive) == nil }) { return d }
    guard let d = devs.first else { fputs("kagami: no video capture devices found\n", stderr); exit(1) }
    return d
}()

var vivid = (ud.object(forKey: "vivid") as? Bool ?? true) && !CommandLine.arguments.contains("--accurate")
var expectedFPS = 60.0   // drop-warning threshold tracks the selected rate

// ---------- modes offered by the current device ----------
struct Mode: Equatable { let w: Int32; let h: Int32 }
func allModes() -> [Mode] {
    var seen = [Mode]()
    for f in cam.formats {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let m = Mode(w: d.width, h: d.height)
        if !seen.contains(m) { seen.append(m) }
    }
    return seen.sorted { Int($0.w) * Int($0.h) > Int($1.w) * Int($1.h) }
}
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
func bestStart() -> (Mode, Double) {
    let m = allModes().first(where: { $0.w == 2560 && $0.h == 1440 }) ?? allModes().first ?? Mode(w: 1920, h: 1080)
    return (m, rates(for: m).first ?? 60)
}

// Must run AFTER the session is running: it renegotiates the device format on
// start (and on input swaps) and silently stomps an earlier pin.
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
            if fps < expectedFPS - 5 {
                fputs(String(format: "kagami: only %.0f fps from device (enq=%d refused=%d flushes=%d)\n",
                             fps, enqueued, refused, flushes), stderr)
            }
            frames = 0; enqueued = 0; refused = 0; flushes = 0; lastReport = now
        }
        // vivid (default): tag frames P3 so the compositor skips gamut mapping —
        // matches the punch of direct HDMI / OBS's unmanaged preview on this panel.
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

let session = AVCaptureSession()
var videoInput: AVCaptureDeviceInput?
let videoFeeder = VideoFeeder(layer: displayLayer)
let videoOut = AVCaptureVideoDataOutput()   // no videoSettings: native format, zero conversion
videoOut.alwaysDiscardsLateVideoFrames = true
videoOut.setSampleBufferDelegate(videoFeeder, queue: DispatchQueue(label: "kagami.video"))

func setVideoDevice(_ dev: AVCaptureDevice) {
    session.beginConfiguration()
    if let vi = videoInput { session.removeInput(vi); videoInput = nil }
    if let inp = try? AVCaptureDeviceInput(device: dev), session.canAddInput(inp) {
        session.addInput(inp); videoInput = inp; cam = dev
    }
    session.commitConfiguration()
    ud.set(cam.uniqueID, forKey: "videoUID")
    let (m, fps) = bestStart()
    applyMode(m, fps: fps)
    controls.reloadModes(selecting: m, fps: fps)
}

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
                fputs("kagami: no converter for \(f), video only\n", stderr); return
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: std)
            do { try engine.start(); player.play() }
            catch { fputs("kagami: audio engine failed (\(error)), video only\n", stderr); return }
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
            fputs("kagami: device audio is silent for 10s (source muted or asleep?)\n", stderr)
            lastSilenceNote = now
        }
        // ponytail: if the source clock outruns the output's, drop buffers past 100ms of
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
var audioInput: AVCaptureDeviceInput?
let audioFeeder = AudioFeeder()

func setAudioDevice(_ dev: AVCaptureDevice?) {
    audioSession.beginConfiguration()
    if let ai = audioInput { audioSession.removeInput(ai); audioInput = nil }
    if let dev, let inp = try? AVCaptureDeviceInput(device: dev), audioSession.canAddInput(inp) {
        audioSession.addInput(inp); audioInput = inp
    }
    audioSession.commitConfiguration()
    ud.set(dev?.uniqueID ?? "none", forKey: "audioUID")
}

func initialAudioDevice() -> AVCaptureDevice? {
    let devs = audioDevices()
    if let uid = ud.string(forKey: "audioUID") {
        if uid == "none" { return nil }
        if let d = devs.first(where: { $0.uniqueID == uid }) { return d }
    }
    // default: audio device that belongs to the chosen video device, by name
    return devs.first(where: { $0.localizedName == cam.localizedName }) ?? devs.first
}

// ---------- overlay controls (mpv-style OSC) ----------
func fpsLabel(_ v: Double) -> String {
    abs(v - v.rounded()) < 0.005 ? String(format: "%.0f fps", v) : String(format: "%.2f fps", v)
}

final class Controls: NSObject {
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 44))
    let volume = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let resPopup = NSPopUpButton(frame: NSRect(x: 190, y: 9, width: 150, height: 26), pullsDown: false)
    let fpsPopup = NSPopUpButton(frame: NSRect(x: 348, y: 9, width: 110, height: 26), pullsDown: false)
    var hideTimer: Timer?
    var modes: [Mode] = []

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
        resPopup.target = self
        resPopup.action = #selector(resChanged(_:))
        box.addSubview(resPopup)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged(_:))
        box.addSubview(fpsPopup)
    }

    func reloadModes(selecting m: Mode, fps: Double) {
        modes = allModes()
        resPopup.removeAllItems()
        resPopup.addItems(withTitles: modes.map { "\($0.w)×\($0.h)" })
        if let i = modes.firstIndex(of: m) { resPopup.selectItem(at: i) }
        fpsPopup.removeAllItems()
        fpsPopup.addItems(withTitles: rates(for: m).map(fpsLabel))
        if let i = rates(for: m).firstIndex(where: { abs($0 - fps) < 0.01 }) { fpsPopup.selectItem(at: i) }
    }

    var currentMode: Mode { modes[max(0, min(resPopup.indexOfSelectedItem, modes.count - 1))] }

    @objc func volumeChanged(_ s: NSSlider) {
        audioFeeder.engine.mainMixerNode.outputVolume = Float(s.doubleValue / 100)
        poke()
    }
    @objc func resChanged(_ s: NSPopUpButton) {
        let m = currentMode
        let best = rates(for: m).first ?? 60
        reloadModes(selecting: m, fps: best)
        applyMode(m, fps: best)
        poke()
    }
    @objc func fpsChanged(_ s: NSPopUpButton) {
        let r = rates(for: currentMode)
        let idx = max(0, s.indexOfSelectedItem)
        if idx < r.count { applyMode(currentMode, fps: r[idx]) }
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

// ---------- settings window ----------
final class Settings: NSObject {
    let win: NSWindow
    let videoPopup = NSPopUpButton(frame: NSRect(x: 140, y: 156, width: 240, height: 26), pullsDown: false)
    let audioPopup = NSPopUpButton(frame: NSRect(x: 140, y: 118, width: 240, height: 26), pullsDown: false)
    let vividCheck = NSButton(checkboxWithTitle: "Vivid color (P3, unmanaged look)", target: nil, action: nil)
    let topCheck = NSButton(checkboxWithTitle: "Keep window on top", target: nil, action: nil)
    var vdevs: [AVCaptureDevice] = []
    var adevs: [AVCaptureDevice] = []

    override init() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        win.title = "kagami Settings"
        win.isReleasedWhenClosed = false
        let content = win.contentView!
        func label(_ text: String, y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 20, y: y, width: 115, height: 20)
            l.alignment = .right
            content.addSubview(l)
        }
        label("Video device:", y: 160)
        label("Audio device:", y: 122)
        videoPopup.target = self; videoPopup.action = #selector(videoChanged(_:))
        audioPopup.target = self; audioPopup.action = #selector(audioChanged(_:))
        vividCheck.frame = NSRect(x: 140, y: 84, width: 240, height: 20)
        vividCheck.target = self; vividCheck.action = #selector(vividChanged(_:))
        topCheck.frame = NSRect(x: 140, y: 56, width: 240, height: 20)
        topCheck.target = self; topCheck.action = #selector(topChanged(_:))
        [videoPopup, audioPopup, vividCheck, topCheck].forEach(content.addSubview)
    }

    @objc func show() {
        vdevs = videoDevices()
        videoPopup.removeAllItems()
        videoPopup.addItems(withTitles: vdevs.map(\.localizedName))
        if let i = vdevs.firstIndex(where: { $0.uniqueID == cam.uniqueID }) { videoPopup.selectItem(at: i) }
        adevs = audioDevices()
        audioPopup.removeAllItems()
        audioPopup.addItems(withTitles: adevs.map(\.localizedName) + ["None"])
        if let cur = audioInput?.device, let i = adevs.firstIndex(where: { $0.uniqueID == cur.uniqueID }) {
            audioPopup.selectItem(at: i)
        } else {
            audioPopup.selectItem(at: adevs.count)   // None
        }
        vividCheck.state = vivid ? .on : .off
        topCheck.state = ud.bool(forKey: "onTop") ? .on : .off
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func videoChanged(_ s: NSPopUpButton) {
        let i = s.indexOfSelectedItem
        if i >= 0 && i < vdevs.count { setVideoDevice(vdevs[i]) }
    }
    @objc func audioChanged(_ s: NSPopUpButton) {
        let i = s.indexOfSelectedItem
        setAudioDevice(i >= 0 && i < adevs.count ? adevs[i] : nil)
    }
    @objc func vividChanged(_ s: NSButton) {
        vivid = s.state == .on
        ud.set(vivid, forKey: "vivid")
    }
    @objc func topChanged(_ s: NSButton) {
        let on = s.state == .on
        ud.set(on, forKey: "onTop")
        window.level = on ? .floating : .normal
    }
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
window.level = ud.bool(forKey: "onTop") ? .floating : .normal
window.center()
window.makeKeyAndOrderFront(nil)

let controls = Controls()
controls.box.frame.origin = NSPoint(x: (view.bounds.width - controls.box.frame.width) / 2, y: 16)
view.addSubview(controls.box)
view.onMove = { controls.poke() }

let settings = Settings()

final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
}
let mainDelegate = MainWindowDelegate()
window.delegate = mainDelegate

// main menu: ⌘, settings, ⌘W close, ⌘Q quit
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
let settingsItem = NSMenuItem(title: "Settings…", action: #selector(Settings.show), keyEquivalent: ",")
settingsItem.target = settings
appMenu.addItem(settingsItem)
appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
appMenu.addItem(NSMenuItem(title: "Quit kagami", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

// ---------- go ----------
guard session.canAddOutput(videoOut) else { fputs("kagami: cannot add video output\n", stderr); exit(1) }
session.addOutput(videoOut)

let audioOut = AVCaptureAudioDataOutput()
audioOut.audioSettings = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 48000,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: false,
]
audioOut.setSampleBufferDelegate(audioFeeder, queue: DispatchQueue(label: "kagami.audio"))
if audioSession.canAddOutput(audioOut) { audioSession.addOutput(audioOut) }
audioSession.startRunning()

session.startRunning()
setVideoDevice(cam)                 // adds input, pins best mode, fills the overlay
setAudioDevice(initialAudioDevice())
controls.poke()                     // show overlay briefly at launch
app.activate()
app.run()
