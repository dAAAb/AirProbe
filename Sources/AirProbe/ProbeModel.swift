import Foundation
import AppKit
import CoreMotion
import Network
import AVFoundation
import CoreAudio
import AirPoiseCore

struct ChartPoint: Identifiable {
    let id: Int
    let t: Double
    let tilt: Double
    let accel: Double
    let gyro: Double
}

struct AudioPoint: Identifiable {
    let id: Int
    let t: Double
    let db: Double
}

struct RecordingItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
    let duration: Double
}

struct LogLine: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
    let important: Bool
}

@MainActor
final class ProbeModel: ObservableObject {
    static let shared = ProbeModel()

    let service = HeadMotionService()
    let analyzer = ProbeAnalyzer()
    let scene = ProbeScene()
    private let recorder = ProbeRecorder()
    private let udp = UDPStreamer()

    // Stream health
    @Published var available = false
    @Published var connected = false
    @Published var authorization: CMAuthorizationStatus = .notDetermined
    @Published var hz: Double = 0
    @Published var ear: SensorEar = .unknown
    @Published var lastSampleAge: Double = .infinity
    @Published var inGap = false
    @Published var gapCount = 0
    @Published var longestGap: Double = 0
    @Published var sampleCount = 0

    // Analysis
    @Published var frame: ProbeFrame?
    @Published var trials: [ProbeTrial] = []
    @Published var log: [LogLine] = []
    @Published var chart: [ChartPoint] = []
    @Published var zeroed = false

    // Output
    @Published var recording = false
    @Published var recordURL: URL?
    @Published var udpOn = false { didSet { udpOn ? udp.start(port: udpPort) : udp.stop() } }
    @Published var udpPort: UInt16 = 9870
    @Published var modelKind: TubeModelKind = .scan { didSet { scene.setKind(modelKind) } }
    @Published var showGhost = true { didSet { scene.setGhostVisible(showGhost) } }

    // Voice (the tube talks)
    let announcer = Announcer()
    private var voiceLogic = PostureVoiceLogic()
    @Published var voiceOn = true { didSet { if voiceOn { voiceLogic.reset() } } }
    @Published var lastLine: String?
    @Published var speaking = false
    @Published var voiceBoost = true { didSet { announcer.boost = voiceBoost } }
    @Published var voiceDrive: Double = 20 { didSet { announcer.setDrive(voiceDrive) } }
    /// Average loudness gain of each line after boost (dB), keyed by text.
    @Published var loudGain: [String: Double] = [:]

    // Standalone audio recorder
    @Published var audioRecording = false
    @Published var audioRecElapsed: Double = 0
    @Published var recordings: [RecordingItem] = []
    @Published var playingURL: URL?
    private var audioRecStart: Date?
    private var audioRecURL: URL?
    private var pendingAudioRec = false
    private var player: AVAudioPlayer?

    // Sound sensor
    let audio = AudioProbe()
    @Published var micOn = false
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedDeviceID: AudioDeviceID?
    @Published var micDeviceName = ""
    @Published var audioDB: Double = -90
    @Published var audioFloorDB: Double = -60
    @Published var onsetCount = 0
    @Published var audioLatencyMs: Double?
    @Published var audioChart: [AudioPoint] = []
    @Published var audioRate: Double = 0
    private var audioBuf = RingBuffer<AudioPoint>(capacity: 400)
    private var audioSeq = 0
    private var lastAudioPublish = Date.distantPast
    private var audioPeakSince = -90.0
    private var onsets: [SoundOnset] = []
    private var imuImpacts: [Double] = []
    private var latencySamples: [Double] = []

    private var lastHost: Date?
    private var gapStart: Date?
    private var lastT: TimeInterval?
    private var emaDt = 1.0 / 25
    private var lastSample: HeadSample?
    private var chartBuf = RingBuffer<ChartPoint>(capacity: 300)
    private var chartSeq = 0
    private var lastChartPublish = Date.distantPast
    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        modelKind = scene.scanLoaded ? .scan : .simple
        service.onSample = { [weak self] s in
            MainActor.assumeIsolated { self?.ingest(s) }
        }
        service.onConnection = { [weak self] c in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.connected != c { self.note(c ? "AirPods 已連線" : "AirPods 斷線", important: !c) }
                self.connected = c
            }
        }
        service.onAvailability = { [weak self] a in
            DispatchQueue.main.async { self?.available = a }
        }
        service.onAuthorization = { [weak self] a in
            DispatchQueue.main.async { self?.authorization = a }
        }
        service.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        note("等待 AirPods 動作資料…（AirPods 要設為這台 Mac 的聲音輸出）")
        announcer.onSpeakingChanged = { [weak self] on in
            MainActor.assumeIsolated {
                self?.speaking = on
                self?.updateSuppression()
            }
        }
        announcer.onClipReady = { [weak self] text, st in
            MainActor.assumeIsolated { self?.loudGain[text] = st.gainDB }
        }
        announcer.prewarm()
        loadRecordings()
        if CommandLine.arguments.contains("--mic-on") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.setMic(true) }
        }
    }

    func resubscribe() {
        service.resubscribe()
        note("重新訂閱動作資料")
    }

    /// Stand the tube upright and still, then zero.
    func zeroUpright() {
        guard let s = lastSample else { return }
        analyzer.zero(with: ProbeSample(s))
        voiceLogic.reset()
        zeroed = true
        note("已歸零：目前姿勢＝直立")
    }

    func clearTrials() {
        analyzer.clearTrials()
        trials = []
    }

    func toggleRecording() {
        if recording {
            recorder.stop()
            audio.stopRecording(tag: "session")
            recording = false
            note("錄製結束：\(recordURL?.lastPathComponent ?? "")")
        } else {
            do {
                recordURL = try recorder.start()
                recording = true
                if micOn, let u = recordURL { startWAV(for: u) }
                note("開始錄製 → \(recordURL!.path)")
            } catch {
                note("無法錄製：\(error.localizedDescription)", important: true)
            }
        }
    }

    func revealRecordings() {
        let dir = ProbeRecorder.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([recordURL ?? dir])
    }

    // MARK: - Sound sensor

    func refreshDevices() {
        inputDevices = AudioInputDevice.all()
        if selectedDeviceID == nil || !inputDevices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = (inputDevices.first(where: { $0.isBluetooth && $0.name.localizedCaseInsensitiveContains("airpods") })
                                ?? inputDevices.first(where: \.isBluetooth)
                                ?? inputDevices.first)?.id
        }
    }

    func setMic(_ on: Bool) {
        if !on {
            audio.stop()
            micOn = false
            note("收音關閉")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startMic()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { ok ? self.startMic() : self.micDenied() }
            }
        default:
            micDenied()
        }
    }

    func restartMic() { if micOn { startMic() } }

    private func micDenied() {
        micOn = false
        note("麥克風權限被拒：系統設定 → 隱私權與安全性 → 麥克風 → 打開 AirProbe", important: true)
    }

    private func startMic() {
        refreshDevices()
        let dev = inputDevices.first { $0.id == selectedDeviceID }
        audio.onFrames = { [weak self] frames in
            DispatchQueue.main.async { self?.ingestAudio(frames) }
        }
        audio.onOnset = { [weak self] o in
            DispatchQueue.main.async { self?.ingestOnset(o) }
        }
        audio.onFormat = { [weak self] sr in
            DispatchQueue.main.async {
                self?.audioRate = sr
                self?.note(String(format: "音訊格式：%.0f kHz", sr / 1000))
            }
        }
        audio.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.note(msg, important: true) }
        }
        do {
            try audio.start(device: dev)
            micOn = true
            micDeviceName = dev?.name ?? "預設輸入"
            audioRate = audio.sampleRate
            onsets = []; latencySamples = []; audioLatencyMs = nil; onsetCount = 0
            note("收音開始：\(micDeviceName)")
            let started = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.micOn, self.audio.buffersReceived == 0, Date().timeIntervalSince(started) >= 3 else { return }
                self.note("⚠️ 3 秒內沒收到任何音訊：檢查麥克風權限，或換一個輸入裝置", important: true)
            }
            if dev?.isBluetooth == true {
                note("注意：AirPods 麥克風會讓藍牙切到通話模式，看「中斷次數」確認動作資料有沒有被影響")
            }
            if recording, let u = recordURL { startWAV(for: u) }
            if pendingAudioRec { pendingAudioRec = false; beginAudioRecording() }
        } catch {
            pendingAudioRec = false
            micOn = false
            note("無法開始收音：\(error.localizedDescription)", important: true)
        }
    }

    // MARK: - Voice

    func testVoice(_ line: Announcer.Line) {
        announcer.say(line)
        lastLine = line.text
    }

    private func announce(_ line: Announcer.Line) {
        announcer.say(line)
        lastLine = line.text
        note("🔊 「\(line.text)」")
        udp.send(["type": "speech", "line": line.rawValue, "text": line.text])
    }

    private func updateSuppression() {
        audio.suppressOnsets = speaking || playingURL != nil
    }

    // MARK: - Standalone recorder

    static var recordingsDirectory: URL {
        ProbeRecorder.directory.appendingPathComponent("recordings", isDirectory: true)
    }

    func toggleAudioRecording() {
        if audioRecording { stopAudioRecording(); return }
        if micOn { beginAudioRecording() }
        else { pendingAudioRec = true; setMic(true) }
    }

    private func beginAudioRecording() {
        let dir = Self.recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let url = dir.appendingPathComponent("rec-\(f.string(from: Date())).wav")
            try audio.startRecording(to: url, tag: "rec")
            audioRecURL = url
            audioRecStart = Date()
            audioRecElapsed = 0
            audioRecording = true
            note("● 開始錄音（\(micDeviceName)）")
        } catch {
            note("無法錄音：\(error.localizedDescription)", important: true)
        }
    }

    private func stopAudioRecording() {
        audio.stopRecording(tag: "rec")
        audioRecording = false
        audioRecStart = nil
        note(String(format: "■ 錄音結束 %.1f 秒：%@", audioRecElapsed, audioRecURL?.lastPathComponent ?? ""))
        // The file is closed when its writer is released; give the audio queue a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.loadRecordings() }
    }

    func loadRecordings() {
        let dir = Self.recordingsDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        recordings = urls.filter { $0.pathExtension == "wav" }.compactMap { u in
            let date = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            var dur = 0.0
            if let f = try? AVAudioFile(forReading: u), f.fileFormat.sampleRate > 0 {
                dur = Double(f.length) / f.fileFormat.sampleRate
            }
            return RecordingItem(url: u, date: date, duration: dur)
        }
        .sorted { $0.date > $1.date }
    }

    func togglePlay(_ item: RecordingItem) {
        if playingURL == item.url {
            player?.stop(); player = nil; playingURL = nil
            updateSuppression()
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: item.url)
            p.play()
            player = p
            playingURL = item.url
            updateSuppression()
        } catch {
            note("無法播放：\(error.localizedDescription)", important: true)
        }
    }

    func deleteRecording(_ item: RecordingItem) {
        if playingURL == item.url { player?.stop(); player = nil; playingURL = nil; updateSuppression() }
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        loadRecordings()
    }

    func revealRecording(_ item: RecordingItem?) {
        let dir = Self.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([item?.url ?? dir])
    }

    private func startWAV(for csv: URL) {
        let wav = csv.deletingPathExtension().appendingPathExtension("wav")
        do {
            try audio.startRecording(to: wav)
            note("同時錄音 → \(wav.lastPathComponent)")
        } catch {
            note("無法錄 WAV：\(error.localizedDescription)", important: true)
        }
    }

    private func ingestAudio(_ frames: [AudioFrame]) {
        guard let last = frames.last else { return }
        for f in frames {
            audioPeakSince = max(audioPeakSince, f.db)
            audioSeq += 1
            if audioSeq % 2 == 0 {   // ~30 Hz into the chart
                audioBuf.push(AudioPoint(id: audioSeq, t: f.t, db: f.db))
            }
        }
        audioFloorDB = last.floorDB
        let now = Date()
        if now.timeIntervalSince(lastAudioPublish) > 0.05 {
            lastAudioPublish = now
            audioDB = audioPeakSince
            udp.send(["type": "audio", "t": last.t, "db": audioPeakSince, "floor_db": last.floorDB])
            audioPeakSince = -90
            audioChart = audioBuf.values
        }
    }

    private func ingestOnset(_ o: SoundOnset) {
        onsetCount += 1
        onsets.append(o)
        onsets.removeAll { o.t - $0.t > 30 }
        udp.send(["type": "sound", "t": o.t, "db": o.db, "rise_db": o.rise])
        note(String(format: "聲音事件 %.0f dB（高於背景 %.0f dB）", o.db, o.rise))
        matchLatency()
    }

    /// Pair IMU impacts with sound onsets to estimate the audio-vs-motion offset.
    private func matchLatency() {
        for imu in imuImpacts {
            // The strongest onset near the impact, not merely the first one.
            if let o = onsets.filter({ $0.t - imu > -0.4 && $0.t - imu < 0.6 }).max(by: { $0.rise < $1.rise }) {
                latencySamples.append(o.t - imu)
            }
        }
        imuImpacts.removeAll { imu in onsets.contains { $0.t - imu > -0.4 && $0.t - imu < 0.6 } }
        if latencySamples.count > 30 { latencySamples.removeFirst(latencySamples.count - 30) }
        if !latencySamples.isEmpty {
            let sorted = latencySamples.sorted()
            audioLatencyMs = sorted[sorted.count / 2] * 1000
        }
    }

    private func enrich(_ tr: ProbeTrial) -> ProbeTrial {
        guard micOn else { return tr }
        var t = tr
        let lag = (audioLatencyMs ?? 0) / 1000
        let end = tr.startTime + tr.duration + lag
        let start = tr.startTime + lag
        let place = audioBuf.values.filter { $0.t >= end - 0.6 && $0.t <= end + 0.6 }.map(\.db).max()
        t.placeSoundDB = place
        t.carrySoundEvents = onsets.filter { $0.t >= start && $0.t < end - 0.6 }.count
        return t
    }

    // MARK: - Stream

    private func ingest(_ s: HeadSample) {
        let now = Date()
        if let gs = gapStart {
            let d = now.timeIntervalSince(gs)
            longestGap = max(longestGap, d)
            note(String(format: "資料恢復（中斷了 %.1f 秒）", d), important: true)
            gapStart = nil
            inGap = false
        }
        lastHost = now
        if let lt = lastT {
            let dt = s.time - lt
            if dt > 0, dt < 1 { emaDt = emaDt * 0.9 + dt * 0.1 }
        }
        lastT = s.time
        hz = 1 / emaDt
        ear = s.ear
        sampleCount += 1
        lastSample = s

        let (f, events) = analyzer.process(ProbeSample(s))
        frame = f
        scene.apply(f.displayOrientation)

        if voiceOn {
            let still = f.state != .moving && f.state != .freeFall
            if let line = voiceLogic.update(t: s.time, tiltDeg: f.tiltDeg, gyro: f.gyro, still: still) {
                announce(line)
            }
        }

        for e in events {
            switch e {
            case .impact(let ti, let g):
                note(String(format: "衝擊 %.2f g", g))
                if micOn {
                    imuImpacts.append(ti)
                    imuImpacts.removeAll { ti - $0 > 5 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.matchLatency() }
                }
                udp.send(["type": "impact", "t": s.time, "g": g])
            case .freeFall(_, let sec):
                note(String(format: "自由落體 %.2f 秒（掉落／被拋起）", sec), important: true)
                udp.send(["type": "freefall", "t": s.time, "seconds": sec])
            case .bump:
                break
            case .trial(let raw):
                let tr = enrich(raw)
                trials.insert(tr, at: 0)
                note("第 \(tr.index) 次放置：\(tr.score) 分 \(tr.passed ? "✓" : "✗")", important: !tr.passed)
                recorder.writeTrial(tr)
                if let data = try? JSONEncoder().encode(tr),
                   var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    obj["type"] = "trial"
                    udp.send(obj)
                }
            }
        }

        recorder.write(sample: s, frame: f)
        if udpOn {
            let q = s.attitude, g = s.gravity, a = s.userAcceleration, w = s.rotationRate
            let d = f.displayOrientation
            udp.send([
                "type": "sample", "t": s.time, "host": now.timeIntervalSince1970,
                "ear": s.ear.rawValue,
                "q": [q.x, q.y, q.z, q.w], "g": [g.x, g.y, g.z],
                "a": [a.x, a.y, a.z], "w": [w.x, w.y, w.z],
                "tilt": f.tiltDeg, "total_g": f.totalG,
                "state": f.state.rawValue, "phase": f.phase.rawValue,
                "q_display": [d.x, d.y, d.z, d.w]
            ])
        }

        chartSeq += 1
        chartBuf.push(ChartPoint(id: chartSeq, t: s.time, tilt: f.tiltDeg, accel: f.accelG, gyro: f.gyro))
        if now.timeIntervalSince(lastChartPublish) > 0.1 {
            lastChartPublish = now
            chart = chartBuf.values
        }
    }

    private func tick() {
        if let st = audioRecStart { audioRecElapsed = Date().timeIntervalSince(st) }
        if playingURL != nil, player?.isPlaying != true {
            player = nil; playingURL = nil; updateSuppression()
        }
        guard let lh = lastHost else { return }
        let age = Date().timeIntervalSince(lh)
        lastSampleAge = age
        if age > 0.6, gapStart == nil {
            gapStart = lh
            inGap = true
            gapCount += 1
            note("⚠️ 資料中斷（可能偵測到離耳、藍牙被遮蔽或超出範圍）", important: true)
        }
        if inGap { hz = 0 }
    }

    private func note(_ text: String, important: Bool = false) {
        log.insert(LogLine(date: Date(), text: text, important: important), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }
}

// MARK: - CSV recorder

final class ProbeRecorder {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirProbe", isDirectory: true)
    }

    private var handle: FileHandle?
    private var trialHandle: FileHandle?

    func start() throws -> URL {
        let dir = Self.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "session-\(f.string(from: Date()))"
        let url = dir.appendingPathComponent(stem + ".csv")
        let header = "host_unix,t,ear,qx,qy,qz,qw,gx,gy,gz,ax,ay,az,wx,wy,wz,tilt_deg,total_g,state,phase\n"
        FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
        handle = try FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        let turl = dir.appendingPathComponent(stem + "-trials.jsonl")
        FileManager.default.createFile(atPath: turl.path, contents: nil)
        trialHandle = try FileHandle(forWritingTo: turl)
        return url
    }

    func stop() {
        try? handle?.close(); handle = nil
        try? trialHandle?.close(); trialHandle = nil
    }

    func write(sample s: HeadSample, frame f: ProbeFrame) {
        guard let handle else { return }
        let q = s.attitude, g = s.gravity, a = s.userAcceleration, w = s.rotationRate
        let line = String(format: "%.4f,%.5f,%@,%.6f,%.6f,%.6f,%.6f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.2f,%.4f,%@,%@\n",
                          s.hostTime.timeIntervalSince1970, s.time, s.ear.rawValue,
                          q.x, q.y, q.z, q.w, g.x, g.y, g.z, a.x, a.y, a.z, w.x, w.y, w.z,
                          f.tiltDeg, f.totalG, f.state.rawValue, f.phase.rawValue)
        handle.write(line.data(using: .utf8)!)
    }

    func writeTrial(_ t: ProbeTrial) {
        guard let trialHandle, var data = try? JSONEncoder().encode(t) else { return }
        data.append(0x0A)
        trialHandle.write(data)
    }
}

// MARK: - UDP JSON stream (one datagram per sample / event)

final class UDPStreamer {
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "airprobe.udp")

    func start(port: UInt16) {
        stop()
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: "127.0.0.1", port: p, using: .udp)
        c.start(queue: queue)
        conn = c
    }

    func stop() {
        conn?.cancel()
        conn = nil
    }

    func send(_ obj: [String: Any]) {
        guard let conn, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }
}
