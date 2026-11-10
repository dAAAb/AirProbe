import Foundation
import AVFoundation

/// The tube talks: speaks a line when its posture changes. Audio goes to the system output,
/// so with the AirPods as output the AirPod inside the tube is the one talking.
///
/// Boost mode renders the speech to PCM first (AVSpeechSynthesizer.write), runs it through
/// LoudSpeech (EQ + compressor + soft clip) and plays the result with AVAudioEngine.
/// It can't exceed full scale; it raises the *average* loudness.
final class Announcer: NSObject, AVSpeechSynthesizerDelegate {
    enum Line: String, CaseIterable {
        case upright, upsideDown, fallen, dizzy

        var text: String {
            switch self {
            case .upright: return "我站起來了！"
            case .upsideDown: return "我顛倒了！"
            case .fallen: return "唉呀！我跌倒了！"
            case .dizzy: return "哇！好暈！"
            }
        }
    }

    struct Clip {
        let raw: [Float]
        let sampleRate: Double
        var loud: [Float]
        var stats: LoudSpeech.Stats
    }

    /// true while speaking (+ a short tail so the mic doesn't count our own voice).
    var onSpeakingChanged: ((Bool) -> Void)?
    /// Fired when a clip finishes (re)processing, with its loudness gain.
    var onClipReady: ((String, LoudSpeech.Stats) -> Void)?
    var rate: Float = 0.52
    var pitch: Float = 1.15
    var boost = true
    private(set) var settings = LoudSpeech.Settings()

    private let synth = AVSpeechSynthesizer()          // plain playback
    private let renderSynth = AVSpeechSynthesizer()    // offline rendering
    private let voice: AVSpeechSynthesisVoice?
    private var tailWork: DispatchWorkItem?

    private let lock = NSLock()
    private var clips: [String: Clip] = [:]
    private var rendering: [String: [(Clip) -> Void]] = [:]
    private let dsp = DispatchQueue(label: "airprobe.loudspeech")

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var engineFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    private var playToken = 0

    override init() {
        let zh = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "zh-TW" }
        voice = zh.first { $0.name.contains("Meijia") || $0.name.contains("美佳") }
            ?? zh.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "zh-TW")
        super.init()
        synth.delegate = self
    }

    var voiceName: String { voice?.name ?? "預設" }

    /// Render the four lines up front so the first reaction has no delay.
    func prewarm() {
        for l in Line.allCases { render(l.text) { _ in } }
    }

    func setDrive(_ db: Double) {
        settings.driveDB = db
        let s = settings
        dsp.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let keys = Array(self.clips.keys)
            self.lock.unlock()
            for k in keys {
                self.lock.lock(); guard var c = self.clips[k] else { self.lock.unlock(); continue }; self.lock.unlock()
                c.loud = LoudSpeech.process(c.raw, sampleRate: c.sampleRate, settings: s)
                c.stats = LoudSpeech.stats(before: c.raw, after: c.loud, sampleRate: c.sampleRate)
                self.lock.lock(); self.clips[k] = c; self.lock.unlock()
                let st = c.stats
                DispatchQueue.main.async { self.onClipReady?(k, st) }
            }
        }
    }

    func clip(for text: String) -> Clip? {
        lock.lock(); defer { lock.unlock() }
        return clips[text]
    }

    func say(_ line: Line) { say(line.text) }

    func say(_ text: String) {
        guard boost else { sayPlain(text); return }
        if let c = clip(for: text) { play(c, text: text); return }
        render(text) { [weak self] c in DispatchQueue.main.async { self?.play(c, text: text) } }
    }

    // MARK: - Plain path

    private func sayPlain(_ text: String) {
        stopAll()
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.pitchMultiplier = pitch
        synth.speak(u)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard s === synth else { return }
        tailWork?.cancel()
        onSpeakingChanged?(true)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { if s === synth { endSoon() } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { if s === synth { endSoon() } }

    private func endSoon() {
        tailWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onSpeakingChanged?(false) }
        tailWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func stopAll() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player?.stop()
    }

    // MARK: - Render → process

    private func render(_ text: String, completion: @escaping (Clip) -> Void) {
        lock.lock()
        if let c = clips[text] { lock.unlock(); completion(c); return }
        if rendering[text] != nil { rendering[text]!.append(completion); lock.unlock(); return }
        rendering[text] = [completion]
        lock.unlock()
        DispatchQueue.main.async { self.renderQueue.append(text); self.pumpRender() }
    }

    /// AVSpeechSynthesizer.write is driven one utterance at a time.
    private var renderQueue: [String] = []
    private var renderBusy = false

    private func pumpRender() {
        guard !renderBusy, !renderQueue.isEmpty else { return }
        renderBusy = true
        let text = renderQueue.removeFirst()
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.pitchMultiplier = pitch
        var samples: [Float] = []
        var sr = 0.0
        renderSynth.write(u) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                let raw = samples, rate = sr
                self.dsp.async { self.finish(text, raw: raw, sampleRate: rate) }
                DispatchQueue.main.async { self.renderBusy = false; self.pumpRender() }
                return
            }
            sr = pcm.format.sampleRate
            samples.append(contentsOf: Self.mono(pcm))
        }
    }

    private func finish(_ text: String, raw: [Float], sampleRate: Double) {
        guard !raw.isEmpty, sampleRate > 0 else {
            lock.lock(); rendering[text] = nil; lock.unlock()
            DispatchQueue.main.async { self.sayPlain(text) }
            return
        }
        let loud = LoudSpeech.process(raw, sampleRate: sampleRate, settings: settings)
        let c = Clip(raw: raw, sampleRate: sampleRate, loud: loud,
                     stats: LoudSpeech.stats(before: raw, after: loud, sampleRate: sampleRate))
        lock.lock()
        clips[text] = c
        let waiters = rendering[text] ?? []
        rendering[text] = nil
        lock.unlock()
        let st = c.stats
        DispatchQueue.main.async { self.onClipReady?(text, st) }
        waiters.forEach { $0(c) }
    }

    static func mono(_ b: AVAudioPCMBuffer) -> [Float] {
        let n = Int(b.frameLength)
        if let f = b.floatChannelData { return Array(UnsafeBufferPointer(start: f[0], count: n)) }
        if let i = b.int16ChannelData { return (0..<n).map { Float(i[0][$0]) / 32768 } }
        if let i = b.int32ChannelData { return (0..<n).map { Float(i[0][$0]) / 2_147_483_648 } }
        return []
    }

    // MARK: - Engine playback

    private func play(_ c: Clip, text: String) {
        stopAll()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: c.sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(c.loud.count)),
              let (engine, player) = ensureEngine(format: fmt) else {
            sayPlain(text)
            return
        }
        buf.frameLength = AVAudioFrameCount(c.loud.count)
        c.loud.withUnsafeBufferPointer { memcpy(buf.floatChannelData![0], $0.baseAddress!, c.loud.count * 4) }
        playToken += 1
        let token = playToken
        tailWork?.cancel()
        onSpeakingChanged?(true)
        player.scheduleBuffer(buf, at: nil, options: [.interrupts], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playToken == token else { return }
                self.endSoon()
            }
        }
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    /// The output device can change format under us (AirPods A2DP ↔ HFP); rebuild when it does.
    private func ensureEngine(format: AVAudioFormat) -> (AVAudioEngine, AVAudioPlayerNode)? {
        if let e = engine, let p = player, e.isRunning, engineFormat == format { return (e, p) }
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        engine?.stop()
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = 1
        do { try e.start() } catch { return nil }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: .main
        ) { [weak self] _ in self?.engine = nil }   // rebuilt lazily on next play
        engine = e; player = p; engineFormat = format
        return (e, p)
    }
}

/// Decides *when* to talk: a posture must hold for a moment and differ from the last line;
/// sustained fast rotation is "dizzy". Pure logic, fed one frame at a time.
struct PostureVoiceLogic {
    var holdSeconds = 0.6
    var uprightMaxDeg = 20.0        // "roughly standing"
    var upsideDownMinDeg = 150.0
    var fallenBand = 60.0...120.0   // lying on its side
    var dizzyGyro = 2.5             // rad/s, smoothed
    var dizzySeconds = 0.5
    var dizzyCooldown = 3.0

    private var candidate: Announcer.Line?
    private var candidateSince = 0.0
    private(set) var last: Announcer.Line?
    private var primed = false
    private var gyroS = 0.0
    private var spinSince: Double?
    private var lastDizzy = -Double.infinity

    mutating func reset() {
        candidate = nil; last = nil; primed = false; spinSince = nil; gyroS = 0
    }

    /// Returns the line to speak for this frame, if any.
    mutating func update(t: Double, tiltDeg: Double, gyro: Double, still: Bool) -> Announcer.Line? {
        gyroS = gyroS * 0.8 + gyro * 0.2
        if gyroS > dizzyGyro {
            if spinSince == nil { spinSince = t }
            if let s = spinSince, t - s >= dizzySeconds, t - lastDizzy >= dizzyCooldown {
                lastDizzy = t
                spinSince = nil
                last = .dizzy          // after the spin, whatever pose it lands in gets announced
                primed = true
                return .dizzy
            }
        } else {
            spinSince = nil
        }

        guard still else { candidate = nil; return nil }
        let pose: Announcer.Line?
        if tiltDeg <= uprightMaxDeg { pose = .upright }
        else if tiltDeg >= upsideDownMinDeg { pose = .upsideDown }
        else if fallenBand.contains(tiltDeg) { pose = .fallen }
        else { pose = nil }
        guard let pose else { candidate = nil; return nil }

        if pose != candidate { candidate = pose; candidateSince = t; return nil }
        guard t - candidateSince >= holdSeconds, pose != last else { return nil }
        last = pose
        // Stay quiet about the pose the tube was already in when we started.
        if !primed { primed = true; return nil }
        return pose
    }
}
