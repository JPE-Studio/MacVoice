// MacVoice — menu bar dictation + tool calling via the Cactus engine (Whistle + Needle 3).
// F5: dictate into the focused text field (tool call if none). F6: tool call. Menu click also works.
import AppKit
import AVFoundation
import Ccactus

// MARK: - Cactus engine

let toolsJSON = """
[{"name":"set_volume","description":"Set the Mac's output volume","parameters":{"type":"object","properties":{"percent":{"type":"integer","description":"0-100"}},"required":["percent"]}},
{"name":"open_app","description":"Open an installed application like Safari, Mail or Spotify (only real app names, not websites)","parameters":{"type":"object","properties":{"app":{"type":"string"}},"required":["app"]}},
{"name":"quit_app","description":"Quit an application","parameters":{"type":"object","properties":{"app":{"type":"string"}},"required":["app"]}},
{"name":"open_url","description":"Open a web address in the browser. Use this for any website or domain like wikipedia.org, never open_app","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}},
{"name":"lock_screen","description":"Lock the screen","parameters":{"type":"object","properties":{}}},
{"name":"sleep_mac","description":"Put the Mac to sleep","parameters":{"type":"object","properties":{}}},
{"name":"take_screenshot","description":"Save a screenshot to the Desktop","parameters":{"type":"object","properties":{}}},
{"name":"say_text","description":"Speak text aloud with the Mac voice. Use when asked to say, speak or announce something (e.g. 'say hello' or 'sag hallo')","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]
"""

/// speech language for recognition; nil = auto-detect (default)
var forcedLanguage: String? {
    let raw = UserDefaults.standard.string(forKey: "language") ?? "auto"
    return raw == "auto" ? nil : raw
}

final class Engine {
    static let shared = Engine()
    private var loaded = false
    private let queue = DispatchQueue(label: "cactus") // engine calls are serialized

    func load() {
        queue.sync {
            guard !loaded else { return }
            for name in ["needle3.cact", "whistle.cact"] {
                // bundled first (self-contained app), fallback: home dir (dev mode)
                let bundled = Bundle.main.resourceURL?.appendingPathComponent(name).path
                let path = [bundled, NSHomeDirectory() + "/" + name].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
                    ?? bundled ?? (NSHomeDirectory() + "/" + name)
                guard let data = FileManager.default.contents(atPath: path) else {
                    fatalError("MacVoice: missing model \(path)")
                }
                let ok = data.withUnsafeBytes { raw -> Int32 in
                    guard let base = raw.baseAddress else { return 0 }
                    return cactus_load(base.assumingMemoryBound(to: UInt8.self), UInt64(data.count))
                }
                if ok != 0 { fatalError("MacVoice: cactus_load failed for \(name): \(String(cString: cactus_last_error()))") }
            }
            cactus_init(nil, toolsJSON, nil)
            forcedLanguage?.withCString { cactus_set_audio($0, nil, 0) } ?? cactus_set_audio(nil, nil, 0)
            loaded = true
        }
    }

    /// apply a language change to the audio tool-call path at runtime
    func setLanguage(_ lang: String?) {
        queue.async {
            lang?.withCString { cactus_set_audio($0, nil, 0) } ?? cactus_set_audio(nil, nil, 0)
            log("engine language -> \(lang ?? "auto")")
        }
    }

    /// pcm 16 kHz mono -> transcription JSON
    func transcribe(_ pcm: [Float], done: @escaping ([String: Any]?) -> Void) {
        queue.async {
            var out = [CChar](repeating: 0, count: 1 << 18)
            let n = pcm.withUnsafeBufferPointer { buf in
                cactus_transcribe(buf.baseAddress, Int32(pcm.count), forcedLanguage, nil, 0, &out, Int32(out.count))
            }
            let result: [String: Any]? = n > 0
                ? (try? JSONSerialization.jsonObject(with: Data(String(cString: out).utf8))) as? [String: Any]
                : nil
            DispatchQueue.main.async { done(result) }
        }
    }

    /// text and/or pcm -> completion JSON (function_calls, audio_text, ...)
    func complete(input: String?, pcm: [Float]?, done: @escaping ([String: Any]?) -> Void) {
        queue.async {
            var out = [CChar](repeating: 0, count: 1 << 18)
            let n: Int32
            if let pcm = pcm {
                n = pcm.withUnsafeBufferPointer { buf in
                    input?.withCString { inC in
                        cactus_complete(inC, buf.baseAddress, Int32(pcm.count), 320, &out, Int32(out.count))
                    } ?? cactus_complete(nil, buf.baseAddress, Int32(pcm.count), 320, &out, Int32(out.count))
                }
            } else {
                n = input!.withCString { inC in
                    cactus_complete(inC, nil, 0, 320, &out, Int32(out.count))
                }
            }
            let result: [String: Any]? = n > 0
                ? (try? JSONSerialization.jsonObject(with: Data(String(cString: out).utf8))) as? [String: Any]
                : nil
            DispatchQueue.main.async { done(result) }
        }
    }
}

// MARK: - Audio recorder (16 kHz mono Float32)

final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private(set) var samples: [Float] = []
    private var lastRMS: Float = 0
    private(set) var inputRate: Double = 0
    private var tapCount = 0
    var onLevel: ((Float) -> Void)? // ~20x/s, called on the audio thread

    var rms: Float { lastRMS }

    /// warm up CoreAudio once at launch so real recordings start in ~100 ms instead of ~3 s
    func prepare() {
        do {
            try setupAndStart()
            Thread.sleep(forTimeInterval: 0.3)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            log("mic warmed up (rate \(inputRate))")
        } catch { log("mic warmup failed: \(error)") }
    }

    func start() throws {
        samples = []
        lastRMS = 0
        tapCount = 0
        try setupAndStart()
    }

    private func setupAndStart() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        inputRate = inFormat.sampleRate
        guard inFormat.sampleRate > 0, let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw NSError(domain: "MacVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mikrofon nicht verfügbar"])
        }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            self?.process(buf, to: outFormat)
        }
        tapCount = 0
        engine.prepare()
        try engine.start()
    }

    private func process(_ buf: AVAudioPCMBuffer, to outFormat: AVAudioFormat) {
        guard let conv = converter else { return }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var err: NSError?
        var fed = false
        conv.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        tapCount += 1
        if tapCount % 25 == 1 { log("tap #\(tapCount): +\(n) samples, total \(samples.count), rms \(lastRMS)") }
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        lastRMS = sqrt(sum / Float(n))
        onLevel?(lastRMS)
    }

    func stop() -> [Float] {
        guard engine.isRunning else { return samples }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return samples
    }
}

// MARK: - on-screen mic indicator

final class WaveView: NSView {
    var history: [Float] = []
    var label: String = ""
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        // red dot = mic live
        NSColor.systemRed.setFill()
        let pulse = 1 + 0.15 * sin(Date().timeIntervalSinceReferenceDate * 8)
        NSBezierPath(ovalIn: NSRect(x: 16, y: bounds.midY - 6 * pulse, width: 12 * pulse, height: 12 * pulse)).fill()
        // label
        (label as NSString).draw(at: NSPoint(x: 38, y: bounds.midY - 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        // waveform: last 26 levels
        let bars = 26
        for i in 0..<bars {
            let idx = history.count - bars + i
            let level: Float = idx >= 0 && idx < history.count ? history[idx] : 0
            let h = max(3, min(34, CGFloat(level) * 90))
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: NSRect(x: 320 + CGFloat(i) * 6, y: bounds.midY - h / 2, width: 3.5, height: h), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

final class MicPanel: NSPanel {
    let waveView = WaveView()
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 500, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        waveView.frame = NSRect(x: 0, y: 0, width: 500, height: 48)
        waveView.wantsLayer = true
        waveView.layer?.cornerRadius = 12
        contentView = waveView
    }
    func show(label: String) {
        waveView.label = label
        waveView.history = []
        if let screen = NSScreen.main {
            let f = screen.frame
            setFrame(NSRect(x: f.midX - 250, y: f.maxY - 120, width: 500, height: 48), display: false)
        }
        orderFrontRegardless()
    }
}

// MARK: - Mac actions (tool execution)

func runCmd(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.standardOutput = Pipe()
    p.standardError = p.standardOutput
    do { try p.run(); p.waitUntilExit() } catch { return "error: \(error)" }
    let data = (p.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ok"
}

func executeTool(_ name: String, _ args: [String: Any]) -> String {
    switch name {
    case "set_volume":
        let pct = max(0, min(100, (args["percent"] as? Int) ?? 50))
        return runCmd(["/usr/bin/osascript", "-e", "set volume output volume \(pct)"])
    case "open_app":
        return runCmd(["/usr/bin/open", "-a", (args["app"] as? String) ?? ""])
    case "quit_app":
        return runCmd(["/usr/bin/osascript", "-e", "tell application \"\((args["app"] as? String) ?? "")\" to quit"])
    case "open_url":
        var url = (args["url"] as? String) ?? ""
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "https://" + url }
        return runCmd(["/usr/bin/open", url])
    case "lock_screen":
        let r = runCmd(["/usr/bin/osascript", "-e", "tell application \"System Events\" to keystroke \"q\" using {command down, control down}"])
        if r.contains("1002") || r.lowercased().contains("not authorized") || r.lowercased().contains("nicht berechtigt") {
            return runCmd(["/usr/bin/pmset", "displaysleepnow"]) + " (display sleep; grant Accessibility for real lock)"
        }
        return r
    case "sleep_mac":
        return runCmd(["/usr/bin/pmset", "sleepnow"])
    case "take_screenshot":
        let path = NSHomeDirectory() + "/Desktop/screenshot_\(Int(Date().timeIntervalSince1970)).png"
        return runCmd(["/usr/sbin/screencapture", "-x", path])
    case "say_text":
        return runCmd(["/usr/bin/say", (args["text"] as? String) ?? ""])
    default:
        return "unknown tool: \(name)"
    }
}

// MARK: - Focused text field + paste

func focusedIsTextField() -> Bool {
    let sys = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let f = focused else { return false }
    let el = unsafeBitCast(f, to: AXUIElement.self)
    var roleRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success, let r = roleRef else { return false }
    let role = unsafeBitCast(r, to: NSString.self) as String
    return role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox" || role == "AXSearchField"
}

func paste(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    usleep(80_000) // let the target app breathe before the paste
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(9), keyDown: true) // V
    down?.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(9), keyDown: false)
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    usleep(30_000)
    up?.post(tap: .cghidEventTap)
}

// MARK: - App

enum Mode { case dictation, toolCall }

let appVersion = "1.2.0"
let gitHubRepo = "JPE-Studio/MacVoice" // GitHub repo for the update check

enum DictKey: String { case rightCmd, rightOpt, f5 }
enum ToolKey: String { case cmdShift, f6, rightOpt }
extension DictKey {
    var label: String { switch self { case .rightCmd: return "right ⌘"; case .rightOpt: return "right ⌥"; case .f5: return "F5" } }
}
extension ToolKey {
    var label: String { switch self { case .cmdShift: return "⌘+⇧"; case .f6: return "F6"; case .rightOpt: return "right ⌥" } }
}

func isNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").compactMap { Int($0) }
    let pb = b.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let path = "/tmp/macvoice.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

final class Controller: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private var recording = false
    private var mode: Mode = .dictation
    private var ready = false
    private var waveTimer: Timer?
    private var waveHistory: [Float] = []
    private var panel: MicPanel?
    private var tap: CFMachPort?
    private var rightCmdDown = false
    private var rightOptDown = false
    private var cmdShiftDown = false
    private var recordingSource: Mode?
    private var dictKey: DictKey = .rightCmd
    private var toolKey: ToolKey = .cmdShift
    private var dictSub = NSMenu()
    private var toolSub = NSMenu()
    private var langSub = NSMenu()
    private var retryTimer: Timer?
    private var statusLine = NSMenuItem(title: "loading models …", action: nil, keyEquivalent: "")
    private var dictItem = NSMenuItem(title: "Diktat (⌘ rechts halten)", action: nil, keyEquivalent: "")
    private var toolItem = NSMenuItem(title: "Tool-Call (F6 halten)", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        log("launch; AX trusted: \(AXIsProcessTrusted())")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        dictKey = DictKey(rawValue: UserDefaults.standard.string(forKey: "dictKey") ?? "") ?? .rightCmd
        toolKey = ToolKey(rawValue: UserDefaults.standard.string(forKey: "toolKey") ?? "") ?? .cmdShift
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(dictItem)
        menu.addItem(toolItem)
        menu.addItem(.separator())
        let dictSettings = NSMenuItem(title: "Dictation key …", action: nil, keyEquivalent: "")
        let toolSettings = NSMenuItem(title: "Tool key …", action: nil, keyEquivalent: "")
        let langSettings = NSMenuItem(title: "Language …", action: nil, keyEquivalent: "")
        for (label, code) in [("Automatic", "auto"), ("English", "en"), ("German", "de"), ("French", "fr"), ("Spanish", "es"), ("Italian", "it"), ("Dutch", "nl"), ("Polish", "pl")] {
            let i = NSMenuItem(title: label, action: #selector(setLanguage(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = code
            langSub.addItem(i)
        }
        langSettings.submenu = langSub
        for (label, key) in [("Rechte ⌘", DictKey.rightCmd), ("Rechte ⌥", DictKey.rightOpt), ("F5", DictKey.f5)] {
            let i = NSMenuItem(title: label, action: #selector(setDictKey(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = key.rawValue
            dictSub.addItem(i)
        }
        for (label, key) in [("⌘+⇧", ToolKey.cmdShift), ("F6", ToolKey.f6), ("Rechte ⌥", ToolKey.rightOpt)] {
            let i = NSMenuItem(title: label, action: #selector(setToolKey(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = key.rawValue
            toolSub.addItem(i)
        }
        dictSettings.submenu = dictSub
        toolSettings.submenu = toolSub
        menu.addItem(dictSettings)
        menu.addItem(toolSettings)
        menu.addItem(langSettings)
        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: "Check for updates", action: #selector(checkForUpdatesMenu), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        let aboutItem = NSMenuItem(title: "About MacVoice", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        dictItem.target = self; dictItem.action = #selector(toggleDictation)
        toolItem.target = self; toolItem.action = #selector(toggleToolCall)
        refreshMenuLabels()
        setIcon("🎙")

        // accessibility prompt (needed for paste + text field detection)
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        installHotkeys()
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.waveHistory.append(level) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            Engine.shared.load()
            log("engine loaded")
            self.recorder.prepare()
            DispatchQueue.main.async {
                self.ready = true
                self.refreshMenuLabels()
                self.statusLine.title = "ready — dictation: \(self.dictKey.label), tool: \(self.toolKey.label)"
                self.autoCheckForUpdates()
            }
        }
    }

    private func setIcon(_ s: String) {
        statusItem?.button?.attributedTitle = NSAttributedString(string: s)
    }

    /// red dot while the mic listens
    private func setRecordingDot() {
        statusItem?.button?.attributedTitle = NSAttributedString(string: "●", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
        ])
    }

    // MARK: recording lifecycle

    private func startRecording(_ mode: Mode) {
        log("startRecording(\(mode == .dictation ? "dictation" : "toolCall")) ready=\(ready) recording=\(recording)")
        guard ready, !recording else { return }
        self.mode = mode
        self.recordingSource = mode
        do {
            try recorder.start()
            log("recorder started, input rate: \(recorder.inputRate)")
            recording = true
            setRecordingDot()
            panel = panel ?? MicPanel()
            panel?.show(label: mode == .dictation ? "Dictation — release to send" : "Tool call")
            waveHistory = []
            waveTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                self?.drawWave()
            }
        } catch {
            log("recorder start failed: \(error)")
            statusLine.title = "Microphone error: \(error.localizedDescription)"
        }
    }

    @objc func toggleDictation() { recording ? stopRecording() : startRecording(.dictation) } // menu fallback: click = toggle
    @objc func toggleToolCall() { recording ? stopRecording() : startRecording(.toolCall) }

    private func stopRecording() {
        guard recording else { log("stop ignored (not recording)"); return }
        waveTimer?.invalidate(); waveTimer = nil
        panel?.orderOut(nil)
        let pcm = recorder.stop()
        recording = false
        recordingSource = nil
        log("stopped, samples: \(pcm.count)")
        setIcon("…")
        statusLine.title = "transcribing …"
        guard pcm.count > 1600 else { finish("(too short)"); return }
        switch mode {
        case .dictation:
            Engine.shared.transcribe(pcm) { [weak self] result in
                guard let self else { return }
                let text = (result?["text"] as? String) ?? ""
                log("transcribed: \"\(text)\" raw=\(result ?? [:])")
                if text.isEmpty { self.finish("(silence)"); return }
                // always paste: works in every app (incl. Electron), no AX guesswork
                paste(text)
                self.finish("✓ \"\(text)\"")
            }
        case .toolCall:
            Engine.shared.complete(input: "", pcm: pcm) { [weak self] r in
                self?.handleCalls(r)
            }
        }
    }

    private func handleCalls(_ result: [String: Any]?) {
        guard let calls = result?["function_calls"] as? [[String: Any]], !calls.isEmpty else {
            let heard = (result?["audio_text"] as? String) ?? ""
            finish(heard.isEmpty ? "no tool recognized" : "no tool for \"\(heard)\"")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var summary: [String] = []
            for call in calls {
                let name = call["name"] as? String ?? "?"
                let args = call["arguments"] as? [String: Any] ?? [:]
                let out = executeTool(name, args)
                summary.append("\(name): \(out)")
            }
            DispatchQueue.main.async {
                self.finish(summary.joined(separator: " | "))
            }
        }
    }

    private func finish(_ message: String) {
        statusLine.title = message
        setIcon(message.hasPrefix("✓") ? "✓" : "🎙")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.setIcon("🎙")
        }
    }

    /// discard the current recording without sending (e.g. another key joined a ⌘⇧ shortcut)
    private func cancelRecording() {
        guard recording else { return }
        waveTimer?.invalidate(); waveTimer = nil
        panel?.orderOut(nil)
        _ = recorder.stop()
        recording = false
        recordingSource = nil
        setIcon("🎙")
        log("cancelled (key joined)")
    }

    // MARK: wave animation (floating panel only; menu bar shows the red dot)

    private func drawWave() {
        let recent = waveHistory.suffix(26)
        waveHistory = Array(recent)
        panel?.waveView.history = waveHistory
        panel?.waveView.needsDisplay = true
    }

    // MARK: settings + updates

    private func refreshMenuLabels() {
        dictItem.title = "Dictation (hold \(dictKey.label))"
        toolItem.title = "Tool Call (hold \(toolKey.label))"
        for i in dictSub.items { i.state = (i.representedObject as? String) == dictKey.rawValue ? .on : .off }
        for i in toolSub.items { i.state = (i.representedObject as? String) == toolKey.rawValue ? .on : .off }
        let lang = UserDefaults.standard.string(forKey: "language") ?? "auto"
        for i in langSub.items { i.state = (i.representedObject as? String) == lang ? .on : .off }
    }

    @objc private func setDictKey(_ sender: NSMenuItem) {
        dictKey = DictKey(rawValue: sender.representedObject as? String ?? "") ?? .rightCmd
        UserDefaults.standard.set(dictKey.rawValue, forKey: "dictKey")
        refreshMenuLabels()
        statusLine.title = "ready — dictation: \(dictKey.label), tool: \(toolKey.label)"
        log("dictKey -> \(dictKey.rawValue)")
    }

    @objc private func setToolKey(_ sender: NSMenuItem) {
        toolKey = ToolKey(rawValue: sender.representedObject as? String ?? "") ?? .cmdShift
        UserDefaults.standard.set(toolKey.rawValue, forKey: "toolKey")
        refreshMenuLabels()
        statusLine.title = "ready — dictation: \(dictKey.label), tool: \(toolKey.label)"
        log("toolKey -> \(toolKey.rawValue)")
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String ?? "auto", forKey: "language")
        refreshMenuLabels()
        Engine.shared.setLanguage(forcedLanguage)
        statusLine.title = "language: \(sender.title)"
        log("language -> \(sender.representedObject ?? "?")")
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MacVoice \(appVersion)"
        alert.informativeText = """
        On-device speech to text + tool calling.
        Whistle STT · Needle 3 · Cactus engine — no cloud, no telemetry.

        Dictation: hold \(dictKey.label)
        Tool call: hold \(toolKey.label)

        github.com/JPE-Studio/MacVoice
        """
        alert.addButton(withTitle: "Open GitHub")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/JPE-Studio/MacVoice")!)
        }
    }

    @objc private func checkForUpdatesMenu() { checkForUpdates(silent: false) } // manual = always show feedback

    /// auto-check once per 24 h
    private func autoCheckForUpdates() {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86400 else { return }
        checkForUpdates(silent: true)
    }

    private func checkForUpdates(silent: Bool) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        guard let url = URL(string: "https://api.github.com/repos/\(gitHubRepo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let resp = resp as? HTTPURLResponse, resp.statusCode == 200,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if !silent {
                    DispatchQueue.main.async {
                        let a = NSAlert()
                        a.messageText = "Update check failed"
                        a.informativeText = "Could not reach github.com/\(gitHubRepo)."
                        a.runModal()
                    }
                }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                if isNewer(latest, than: appVersion) {
                    self.offerUpdate(tag: tag, json: json)
                } else if !silent {
                    let a = NSAlert()
                    a.messageText = "You're up to date"
                    a.informativeText = "MacVoice v\(appVersion) is the latest version."
                    a.runModal()
                    self.statusLine.title = "up to date (v\(appVersion))"
                }
            }
        }.resume()
    }

    private func offerUpdate(tag: String, json: [String: Any]) {
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String) == "MacVoice.zip" }
        let alert = NSAlert()
        alert.messageText = "Update available: v\(tag)"
        alert.informativeText = "Version \(tag) is available on GitHub. Download now?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, let urlStr = zip?["browser_download_url"] as? String, let url = URL(string: urlStr) {
            let dest = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/MacVoice-\(tag).zip")
            statusLine.title = "downloading v\(tag) …"
            URLSession.shared.downloadTask(with: url) { localUrl, _, _ in
                guard let localUrl else { return }
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.moveItem(at: localUrl, to: dest)
                // unzip next to it and reveal in Finder
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-x", "-k", dest.path, dest.deletingLastPathComponent().path]
                try? proc.run(); proc.waitUntilExit()
                DispatchQueue.main.async {
                    self.statusLine.title = "✓ update unzipped to Downloads — replace the app in /Applications"
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dest.deletingLastPathComponent().path)
                }
            }.resume()
        }
    }

    // MARK: global hotkeys (CGEvent tap: true key-up, no auto-repeat storm)

    private func installHotkeys() {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = me.handleKeyEvent(type, event)
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        if let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(mask), callback: callback,
                                    userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            tap = t
            retryTimer?.invalidate()
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
            log("event tap installed")
        } else {
            log("event tap FAILED — accessibility permission missing")
            statusLine.title = "⚠️ Accessibility missing: System Settings → Privacy & Security → Accessibility"
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard AXIsProcessTrusted() else { return }
                self?.installHotkeys()
            }
        }
    }

    /// returns true = swallow the event
    private func handleKeyEvent(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return false
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        switch type {
        case .flagsChanged:
            if keyCode == 54 { // right command
                let down = (event.flags.rawValue & 0x10) != 0 // NX_DEVICERCMDKEYMASK (IOLLEvent.h)
                if down && !rightCmdDown, dictKey == .rightCmd {
                    DispatchQueue.main.async { self.startRecording(.dictation) }
                }
                if !down && rightCmdDown, dictKey == .rightCmd, recordingSource == .dictation {
                    DispatchQueue.main.async { self.stopRecording() }
                }
                rightCmdDown = down
            }
            if keyCode == 63 { // right option
                let down = (event.flags.rawValue & 0x40) != 0 // NX_DEVICERALTKEYMASK
                if down && !rightOptDown {
                    if dictKey == .rightOpt { DispatchQueue.main.async { self.startRecording(.dictation) } }
                    if toolKey == .rightOpt { DispatchQueue.main.async { self.startRecording(.toolCall) } }
                }
                if !down && rightOptDown, recordingSource != nil {
                    DispatchQueue.main.async { self.stopRecording() }
                }
                rightOptDown = down
            }
            if toolKey == .cmdShift { // ⌘+⇧ held = tool call
                let both = event.flags.contains(.maskCommand) && event.flags.contains(.maskShift)
                if both && !cmdShiftDown, recordingSource == nil {
                    DispatchQueue.main.async { self.startRecording(.toolCall) }
                }
                if !both && cmdShiftDown, recordingSource == .toolCall {
                    DispatchQueue.main.async { self.stopRecording() }
                }
                cmdShiftDown = both
            }
            return false
        case .keyDown:
            // another key joins a held modifier combo (e.g. ⌘⇧4 screenshot) → cancel silently
            if recordingSource == .toolCall, toolKey == .cmdShift, !isRepeat {
                DispatchQueue.main.async { self.cancelRecording() }
                return false
            }
            if keyCode == 96, dictKey == .f5 {
                if !isRepeat { DispatchQueue.main.async { self.startRecording(.dictation) } }
                return true // swallow: no brightness change
            }
            if keyCode == 97, toolKey == .f6 {
                if !isRepeat { DispatchQueue.main.async { self.startRecording(.toolCall) } }
                return true
            }
            return false
        case .keyUp:
            if keyCode == 96, dictKey == .f5 { DispatchQueue.main.async { self.stopRecording() }; return true }
            if keyCode == 97, toolKey == .f6 { DispatchQueue.main.async { self.stopRecording() }; return true }
            return false
        default:
            return false
        }
    }
}

// MARK: - main

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory) // menu bar only, no dock icon
app.run()
