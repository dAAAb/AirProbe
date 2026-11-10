import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// An input device (AirPods mic, built-in mic, …) as seen by Core Audio.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isBluetooth: Bool
    /// Core Audio UID; equals AVCaptureDevice.uniqueID for audio devices on macOS.
    let uid: String

    static func all() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0 else { return nil }
            let t = transport(id)
            return AudioInputDevice(id: id, name: name(id),
                                    isBluetooth: t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE,
                                    uid: string(id, kAudioDevicePropertyDeviceUID))
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(_ id: AudioDeviceID) -> String {
        string(id, kAudioObjectPropertyName)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "Device \(id)" }
        return n.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }
}

/// One analysis frame (~16 ms). `t` is on the same clock as CMDeviceMotion.timestamp
/// (mach host time, seconds since boot), so audio and IMU share one time axis.
struct AudioFrame {
    let t: Double
    let db: Double        // RMS dBFS
    let peakDB: Double
    let floorDB: Double
}

struct SoundOnset {
    let t: Double
    let db: Double
    let rise: Double      // dB above the noise floor
}

/// Mic capture + level / onset detection + optional WAV recording.
/// Callbacks arrive on the audio tap thread; the owner hops to main.
final class AudioProbe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onFrames: (([AudioFrame]) -> Void)?
    var onOnset: ((SoundOnset) -> Void)?
    var onError: ((String) -> Void)?
    /// Called once per (re)negotiated stream format, e.g. 48 kHz → 24 kHz when AirPods enter HFP.
    var onFormat: ((Double) -> Void)?

    private(set) var running = false
    private(set) var sampleRate: Double = 0
    private(set) var buffersReceived = 0

    // AVCaptureSession copes with Bluetooth profile switches (format changes) on its own;
    // AVAudioEngine with a manually-set device throws "Format mismatch" when AirPods drop to 24 kHz.
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "airprobe.audio")
    private var runtimeObserver: NSObjectProtocol?

    /// Several WAV writers can run at once (e.g. the CSV session and a standalone recording).
    private var files: [String: AVAudioFile] = [:]
    private var pending: [String: URL] = [:]
    private let fileLock = NSLock()
    private var _suppress = false
    /// True while the app itself is playing sound (speech, playback) — onsets are ignored.
    var suppressOnsets: Bool {
        get { fileLock.lock(); defer { fileLock.unlock() }; return _suppress }
        set { fileLock.lock(); _suppress = newValue; fileLock.unlock() }
    }

    // Detector state (audio queue only)
    private var floorDB = -60.0
    private var lastDB = -90.0
    private var lastOnset = -Double.infinity
    /// Onset = frame this many dB above the adaptive noise floor and rising fast.
    var onsetRiseDB = 15.0

    func start(device: AudioInputDevice?) throws {
        stop()
        let capDevice = Self.captureDevice(matching: device)
        guard let capDevice else {
            throw NSError(domain: "AirProbe", code: -1, userInfo: [NSLocalizedDescriptionKey: "找不到可擷取的麥克風"])
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: capDevice)
        guard session.canAddInput(input) else {
            throw NSError(domain: "AirProbe", code: -2, userInfo: [NSLocalizedDescriptionKey: "無法使用 \(capDevice.localizedName)"])
        }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        // Native sample rate (AirPods mic = 24 kHz), mono Float32 non-interleaved.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "AirProbe", code: -3, userInfo: [NSLocalizedDescriptionKey: "無法建立音訊輸出"])
        }
        session.addOutput(output)
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { [weak self] n in
            let e = n.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?("收音中斷：\(e?.localizedDescription ?? "未知錯誤")")
        }
        queue.async {
            self.floorDB = -60; self.lastDB = -90; self.lastOnset = -.infinity
            self.sampleRate = 0; self.buffersReceived = 0
        }
        self.session = session
        running = true
        queue.async { session.startRunning() }
    }

    func stop() {
        if let o = runtimeObserver { NotificationCenter.default.removeObserver(o) }
        runtimeObserver = nil
        if let s = session { queue.async { s.stopRunning() } }
        session = nil
        running = false
        stopRecording()
    }

    /// WAV is opened on the first buffer, once the real sample rate is known.
    func startRecording(to url: URL, tag: String = "session") throws {
        fileLock.lock(); pending[tag] = url; files[tag] = nil; fileLock.unlock()
    }

    func stopRecording(tag: String) {
        fileLock.lock(); files[tag] = nil; pending[tag] = nil; fileLock.unlock()
    }

    func stopRecording() {
        fileLock.lock(); files.removeAll(); pending.removeAll(); fileLock.unlock()
    }

    private static func captureDevice(matching d: AudioInputDevice?) -> AVCaptureDevice? {
        let all = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        guard let d else { return AVCaptureDevice.default(for: .audio) }
        return all.first { $0.uniqueID == d.uid }
            ?? all.first { $0.localizedName == d.name }
            ?? AVCaptureDevice.default(for: .audio)
    }

    // MARK: - Capture callback

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let sr = asbd.mSampleRate
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block)
        guard st == noErr, let data = abl.mBuffers.mData else { return }
        let n = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        // PTS is on the host clock (same as CMDeviceMotion.timestamp / systemUptime).
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let t0 = pts.isValid ? CMTimeGetSeconds(pts) : ProcessInfo.processInfo.systemUptime - Double(n) / sr
        analyze(data.assumingMemoryBound(to: Float.self), count: n, sampleRate: sr, t0: t0)
    }

    // MARK: - Analysis (also used by selfTest)

    func analyze(_ p: UnsafePointer<Float>, count n: Int, sampleRate sr: Double, t0: Double) {
        guard n > 0, sr > 0 else { return }
        buffersReceived += 1
        if sr != sampleRate {
            sampleRate = sr
            onFormat?(sr)
        }
        writeWAV(p, count: n, sampleRate: sr)

        let hop = max(128, Int(sr * 0.016))
        var frames: [AudioFrame] = []
        var i = 0
        while i < n {
            let m = min(hop, n - i)
            var sum: Float = 0, peak: Float = 0
            for k in 0..<m {
                let v = p[i + k]
                sum += v * v
                peak = max(peak, abs(v))
            }
            let rms = (sum / Float(m)).squareRoot()
            let db = 20 * log10(max(Double(rms), 1e-6))
            let pdb = 20 * log10(max(Double(peak), 1e-6))
            let t = t0 + Double(i) / sr
            // Bluetooth dropouts deliver digital silence; don't let them drag the floor down.
            let dropout = db < -100
            // Noise floor: falls fast toward quieter frames, always creeps up (~3 dB/s)
            // so a single quiet glitch can't pin it low forever.
            if !dropout {
                if db < floorDB { floorDB = floorDB * 0.7 + db * 0.3 }
                else { floorDB += min(db - floorDB, 3.0 * Double(m) / sr) }
                floorDB = max(floorDB, -100)
            }
            let rise = db - floorDB
            if !dropout, !suppressOnsets, rise > onsetRiseDB, db - lastDB > 6, t - lastOnset > 0.15 {
                lastOnset = t
                onOnset?(SoundOnset(t: t, db: pdb, rise: rise))
            }
            if !dropout { lastDB = db }
            frames.append(AudioFrame(t: t, db: db, peakDB: pdb, floorDB: floorDB))
            i += m
        }
        onFrames?(frames)
    }

    private func writeWAV(_ p: UnsafePointer<Float>, count n: Int, sampleRate sr: Double) {
        fileLock.lock(); defer { fileLock.unlock() }
        for (tag, url) in pending {
            files[tag] = try? AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        pending.removeAll()
        for file in files.values where file.processingFormat.sampleRate == sr {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else { continue }
            buf.frameLength = AVAudioFrameCount(n)
            memcpy(buf.floatChannelData![0], p, n * MemoryLayout<Float>.size)
            try? file.write(from: buf)
        }
    }

    /// Offline check: background noise with three clicks → expect 3 onsets.
    static func selfTest() -> [SoundOnset] {
        let sr = 24_000.0
        let probe = AudioProbe()
        var found: [SoundOnset] = []
        probe.onOnset = { found.append($0) }
        var rng = SystemRandomNumberGenerator()
        let clicks: Set<Int> = [1, 3, 4]               // seconds at which a click happens
        let n = 1200                                   // 50 ms blocks
        var block = [Float](repeating: 0, count: n)
        for blk in 0..<(5 * Int(sr) / n) {
            for k in 0..<n {
                let idx = blk * n + k
                var v = Float(Double.random(in: -1...1, using: &rng)) * 0.003      // ≈ -55 dBFS floor
                if idx >= Int(sr * 0.5), idx < Int(sr * 0.5) + 400 { v = 0 }          // BT dropout
                if clicks.contains(idx / Int(sr)), idx % Int(sr) < 600 {
                    v += Float(sin(Double(idx) * 0.9)) * 0.5 * Float(exp(-Double(idx % Int(sr)) / 180))
                }
                block[k] = v
            }
            block.withUnsafeBufferPointer {
                probe.analyze($0.baseAddress!, count: n, sampleRate: sr, t0: 1000 + Double(blk * n) / sr)
            }
        }
        return found
    }
}
