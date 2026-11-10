import SwiftUI
import AppKit
import AVFoundation
import AirPoiseCore

@main
struct AirProbeApp: App {
    @NSApplicationDelegateAdaptor(ProbeAppDelegate.self) var delegate
    @StateObject private var model = ProbeModel.shared

    var body: some Scene {
        WindowGroup("AirProbe · 活萃力管") {
            ProbeView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1180, height: 760)
    }
}

final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Self-check: `AirProbe --snapshot out.png [tiltDeg]` renders the 3D tube and exits.
        let args = CommandLine.arguments
        if args.contains("--list-inputs") {
            for d in AudioInputDevice.all() { print("\(d.id)\t\(d.isBluetooth ? "BT " : "   ")\(d.name)") }
            exit(0)
        }
        if let i = args.firstIndex(of: "--mic-test"), i + 2 < args.count {
            // `--mic-test <seconds> <out.txt>`: capture from the AirPods (or default) mic and log levels.
            let secs = Double(args[i + 1]) ?? 5
            let out = URL(fileURLWithPath: args[i + 2])
            var lines = ["auth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3=authorized)"]
            let dev = AudioInputDevice.all().first { $0.isBluetooth && $0.name.localizedCaseInsensitiveContains("airpods") }
            lines.append("device=\(dev?.name ?? "default") uid=\(dev?.uid ?? "-")")
            let probe = AudioProbe()
            var maxDB = -200.0, frames = 0, onsets = 0, firstT = 0.0, lastT = 0.0
            let lock = NSLock()
            probe.onFrames = { fs in
                lock.lock(); defer { lock.unlock() }
                for f in fs { maxDB = max(maxDB, f.db); if frames == 0 { firstT = f.t }; lastT = f.t; frames += 1 }
            }
            probe.onOnset = { _ in lock.lock(); onsets += 1; lock.unlock() }
            probe.onFormat = { sr in lock.lock(); lines.append("format=\(sr) Hz"); lock.unlock() }
            probe.onError = { e in lock.lock(); lines.append("error=\(e)"); lock.unlock() }
            let wav = out.deletingPathExtension().appendingPathExtension("wav")
            do {
                try probe.start(device: dev)
                try probe.startRecording(to: wav, tag: "rec")
            } catch { lines.append("start error=\(error.localizedDescription)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                probe.stop()
                if let f = try? AVAudioFile(forReading: wav) {
                    lines.append(String(format: "wav=%@ %.2fs @ %.0f Hz", wav.lastPathComponent, Double(f.length) / f.fileFormat.sampleRate, f.fileFormat.sampleRate))
                } else { lines.append("wav=missing") }
                lock.lock()
                lines.append("buffers=\(probe.buffersReceived) frames=\(frames) span=\(String(format: "%.2f", lastT - firstT))s maxDB=\(String(format: "%.1f", maxDB)) onsets=\(onsets)")
                lines.append("now_uptime=\(ProcessInfo.processInfo.systemUptime) last_t=\(lastT)")
                lock.unlock()
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        if args.contains("--voice-selftest") {
            // stand (silent: initial pose) → fall on side → upside down → spin → stand
            var logic = PostureVoiceLogic()
            var said: [String] = []
            var t = 0.0
            func run(_ secs: Double, tilt: Double, gyro: Double) {
                for _ in 0..<Int(secs * 50) {
                    t += 0.02
                    let still = gyro < 0.3
                    if let l = logic.update(t: t, tiltDeg: tilt, gyro: gyro, still: still) {
                        said.append(String(format: "%.2fs %@", t, l.text))
                    }
                }
            }
            run(2, tilt: 3, gyro: 0); run(0.5, tilt: 50, gyro: 1.0); run(2, tilt: 92, gyro: 0)
            run(0.5, tilt: 130, gyro: 1.0); run(2, tilt: 175, gyro: 0)
            run(1.2, tilt: 90, gyro: 4.0); run(2, tilt: 8, gyro: 0)
            said.forEach { print($0) }
            exit(said.count == 4 ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--loud-selftest"), i + 1 < args.count {
            // Render the four lines offline, boost them, write raw/loud WAVs, print loudness stats.
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ann = Announcer()
            if let d = args.firstIndex(of: "--drive"), d + 1 < args.count, let v = Double(args[d + 1]) { ann.setDrive(v) }
            var done = Set<String>()
            ann.onClipReady = { text, st in
                guard !done.contains(text), let c = ann.clip(for: text) else { return }
                done.insert(text)
                let idx = Announcer.Line.allCases.firstIndex { $0.text == text } ?? 0
                for (tag, data) in [("raw", c.raw), ("loud", c.loud)] {
                    let fmt = AVAudioFormat(standardFormatWithSampleRate: c.sampleRate, channels: 1)!
                    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(data.count))!
                    b.frameLength = AVAudioFrameCount(data.count)
                    data.withUnsafeBufferPointer { memcpy(b.floatChannelData![0], $0.baseAddress!, data.count * 4) }
                    if let f = try? AVAudioFile(forWriting: dir.appendingPathComponent("line\(idx)-\(tag).wav"), settings: fmt.settings) {
                        try? f.write(from: b)
                    }
                }
                print(String(format: "%@  %.0f Hz %.2fs  RMS %.1f → %.1f dBFS (+%.1f dB)  peak %.1f → %.1f dBFS",
                             text, c.sampleRate, Double(c.raw.count) / c.sampleRate,
                             st.rmsBeforeDB, st.rmsAfterDB, st.gainDB, st.peakBeforeDB, st.peakAfterDB))
                if done.count == Announcer.Line.allCases.count { exit(0) }
            }
            ann.prewarm()
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout, got \(done.count)"); exit(1) }
            return
        }
        if args.contains("--audio-selftest") {
            let o = AudioProbe.selfTest()
            for e in o { print(String(format: "onset t=%.3f (rel %.3f s)  peak %.1f dBFS  rise %.1f dB", e.t, e.t - 1000, e.db, e.rise)) }
            print("onsets=\(o.count) (expect 3 at ~1, 3, 4 s)")
            exit(o.count == 3 ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            let tilt = i + 2 < args.count ? Double(args[i + 2]) ?? 0 : 0
            let kind = args.contains("--simple") ? TubeModelKind.simple : .scan
            MainActor.assumeIsolated {
                let scene = ProbeModel.shared.scene
                scene.setKind(kind)
                let th = Angle.rad(tilt) / 2
                scene.apply(Quat(x: sin(th), y: 0, z: 0, w: cos(th)))
                let img = scene.snapshot(size: CGSize(width: 900, height: 700))
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: out)
                }
                print("scanLoaded=\(scene.scanLoaded) wrote \(out.path)")
            }
            exit(0)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
