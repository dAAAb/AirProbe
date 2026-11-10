import SwiftUI
import SceneKit
import Charts
import AirPoiseCore

struct ProbeView: View {
    @EnvironmentObject var model: ProbeModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    SceneView(
                        scene: model.scene.scene,
                        pointOfView: model.scene.cameraNode,
                        options: [.allowsCameraControl, .rendersContinuously]
                    )
                    StateBadge(frame: model.frame, inGap: model.inGap)
                        .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ChartsPanel(points: model.chart, audio: model.micOn ? model.audioChart : [])
                    .frame(height: model.micOn ? 310 : 240)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            Divider()
            SidePanel()
                .frame(width: 340)
        }
        .frame(minWidth: 1040, minHeight: 700)
    }
}

// MARK: - Badge

private struct StateBadge: View {
    let frame: ProbeFrame?
    let inGap: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if inGap {
                Text("資料中斷")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(.red)
                Text("耳機沒有送資料過來")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let f = frame {
                Text(f.state.label)
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(color(f.state))
                Text(String(format: "傾斜 %.1f°", f.tiltDeg))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(String(format: "加速度 %.2f g · 角速度 %.2f rad/s", f.accelG, f.gyro))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if !f.calibrated {
                    Text("尚未歸零").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("等待資料").font(.system(size: 34, weight: .heavy)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func color(_ s: ProbeState) -> Color {
        switch s {
        case .upright: return .green
        case .tilted: return .orange
        case .lying, .upsideDown: return .red
        case .moving: return .blue
        case .freeFall: return .purple
        case .unknown: return .secondary
        }
    }
}

// MARK: - Charts

private struct ChartsPanel: View {
    let points: [ChartPoint]
    let audio: [AudioPoint]

    var body: some View {
        let t1 = max(points.last?.t ?? 0, audio.last?.t ?? 0)
        let t0 = t1 - 12
        VStack(spacing: 14) {
            series("傾斜 °", \.tilt, color: .green, domain: 0...180, ticks: [0, 90, 180], t0: t0, t1: t1)
            series("加速度 g", \.accel, color: .blue, domain: 0...1.0, ticks: [0, 0.5, 1], t0: t0, t1: t1)
            series("角速度 rad/s", \.gyro, color: .orange, domain: 0...6, ticks: [0, 3, 6], t0: t0, t1: t1)
            if !audio.isEmpty {
                HStack(spacing: 8) {
                    Text("音量 dBFS").font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    Chart(audio) { p in
                        LineMark(x: .value("t", p.t), y: .value("dB", max(p.db, -80)))
                            .foregroundStyle(.pink)
                    }
                    .chartXScale(domain: t0...max(t1, t0 + 1))
                    .chartYScale(domain: -80...0)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [-80, -40, 0]) { _ in
                            AxisGridLine()
                            AxisValueLabel().font(.caption2)
                        }
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    private func series(_ title: String, _ kp: KeyPath<ChartPoint, Double>, color: Color,
                        domain: ClosedRange<Double>, ticks: [Double], t0: Double, t1: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Chart(points) { p in
                LineMark(x: .value("t", p.t), y: .value(title, min(p[keyPath: kp], domain.upperBound)))
                    .foregroundStyle(color)
                    .interpolationMethod(.linear)
            }
            .chartXScale(domain: t0...max(t1, t0 + 1))
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: ticks) { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.caption2)
                }
            }
        }
    }
}

// MARK: - Side panel

private struct SidePanel: View {
    @EnvironmentObject var model: ProbeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                streamBox
                zeroBox
                trialBox
                voiceBox
                soundBox
                recorderBox
                outputBox
                logBox
            }
            .padding(16)
        }
    }

    private var streamBox: some View {
        GroupBox("資料流") {
            VStack(alignment: .leading, spacing: 6) {
                row("狀態", streamStatus, color: model.inGap ? .red : (model.hz > 5 ? .green : .orange))
                row("取樣率", model.hz > 0 ? String(format: "%.1f Hz", model.hz) : "—")
                row("來源", earLabel)
                row("最後一筆", model.lastSampleAge.isFinite ? String(format: "%.2f 秒前", model.lastSampleAge) : "—")
                row("中斷次數", model.gapCount == 0 ? "0" : String(format: "%d（最長 %.1f 秒）", model.gapCount, model.longestGap))
                row("樣本數", "\(model.sampleCount)")
                HStack {
                    Button("重新訂閱") { model.resubscribe() }
                    if model.authorization == .denied || model.authorization == .restricted {
                        Text("動作權限被拒：系統設定 → 隱私權 → 動作與健身").font(.caption).foregroundStyle(.red)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var zeroBox: some View {
        GroupBox("歸零") {
            VStack(alignment: .leading, spacing: 8) {
                Text("把 AirPods 放進管子，管子立正放在桌上不要動，再按歸零。之後所有傾斜角都以這個姿勢為 0°。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        model.zeroUpright()
                    } label: {
                        Label("歸零（現在是直立）", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.frame == nil)
                    if model.zeroed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                HStack {
                    Picker("模型", selection: $model.modelKind) {
                        ForEach(TubeModelKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!model.scene.scanLoaded)
                    Toggle("目標框", isOn: $model.showGhost)
                }
            }
        }
    }

    private var trialBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let t = model.trials.first {
                    TrialCard(trial: t)
                } else {
                    Text("拿起管子 → 搬動 → 放下，靜止 0.6 秒後自動評分。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.trials.count > 1 {
                    Divider()
                    ForEach(model.trials.dropFirst().prefix(12)) { t in
                        HStack {
                            Text("#\(t.index)").monospacedDigit().foregroundStyle(.secondary)
                            Text(t.passed ? "✓" : "✗").foregroundStyle(t.passed ? .green : .red)
                            Text("\(t.score) 分").monospacedDigit()
                            Spacer()
                            Text(String(format: "最大 %.0f° · %.2f g", t.maxTiltDeg, t.placeImpactG))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Pick & Place 評分")
                Spacer()
                if !model.trials.isEmpty {
                    let pass = model.trials.filter(\.passed).count
                    Text("\(pass)/\(model.trials.count) 成功").font(.caption).foregroundStyle(.secondary)
                    Button("清除") { model.clearTrials() }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    private var voiceBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("姿勢改變時說話", isOn: $model.voiceOn)
                Text("站著 → 我站起來了！　倒過來 → 我顛倒了！\n側躺 → 唉呀！我跌倒了！　搖晃 → 哇！好暈！")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("試聽").font(.caption).foregroundStyle(.secondary)
                    ForEach(Announcer.Line.allCases, id: \.self) { line in
                        Button(shortLabel(line)) { model.testVoice(line) }
                            .controlSize(.small)
                    }
                }
                Divider()
                Toggle("增強音量（放大＋壓縮器）", isOn: $model.voiceBoost)
                if model.voiceBoost {
                    HStack {
                        Text("強度").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $model.voiceDrive, in: 0...26, step: 1)
                        Text("\(Int(model.voiceDrive)) dB").font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    if !model.loudGain.isEmpty {
                        let g = model.loudGain.values.reduce(0, +) / Double(model.loudGain.count)
                        Text(String(format: "平均響度 +%.1f dB（不超過滿刻度；越高越大聲，也越「扁」）", g))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let l = model.lastLine {
                    HStack {
                        Image(systemName: model.speaking ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(model.speaking ? .green : .secondary)
                        Text("「\(l)」").font(.callout)
                    }
                }
                Text("聲音從系統輸出播放：AirPods 是輸出時，就是管子裡那支在說話。說話時暫停偵測聲音事件，避免把自己的聲音算進去。語音：\(model.announcer.voiceName)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("語音反應")
        }
    }

    private func shortLabel(_ l: Announcer.Line) -> String {
        switch l {
        case .upright: return "站"
        case .upsideDown: return "倒"
        case .fallen: return "跌"
        case .dizzy: return "暈"
        }
    }

    private var recorderBox: some View {
        GroupBox("錄音") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        model.toggleAudioRecording()
                    } label: {
                        Label(model.audioRecording ? "停止" : "開始錄音",
                              systemImage: model.audioRecording ? "stop.circle.fill" : "mic.circle.fill")
                    }
                    .tint(model.audioRecording ? .red : nil)
                    .buttonStyle(.borderedProminent)
                    if model.audioRecording {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(timeString(model.audioRecElapsed)).monospacedDigit()
                    }
                    Spacer()
                    Button("資料夾") { model.revealRecording(nil) }.buttonStyle(.borderless).font(.caption)
                }
                if !model.micOn && !model.audioRecording {
                    Text("按下會自動開啟收音（用上面選的輸入裝置）").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.recordings.prefix(8)) { r in
                    HStack(spacing: 8) {
                        Button {
                            model.togglePlay(r)
                        } label: {
                            Image(systemName: model.playingURL == r.url ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderless)
                        Text(r.date, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
                            .font(.caption.monospaced())
                        Text(timeString(r.duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button { model.revealRecording(r) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                        Button { model.deleteRecording(r) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timeString(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var soundBox: some View {
        GroupBox("聲音感測") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("輸入", selection: $model.selectedDeviceID) {
                        ForEach(model.inputDevices) { d in
                            Text(d.isBluetooth ? "🎧 \(d.name)" : d.name).tag(Optional(d.id))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: model.selectedDeviceID) { _, _ in model.restartMic() }
                    Button {
                        model.refreshDevices()
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                }
                Toggle("啟用收音", isOn: Binding(get: { model.micOn }, set: { model.setMic($0) }))
                if model.micOn {
                    LevelMeter(db: model.audioDB, floor: model.audioFloorDB)
                        .frame(height: 10)
                    HStack {
                        Text(String(format: "%.0f dB", model.audioDB)).monospacedDigit()
                        Text(String(format: "背景 %.0f dB", model.audioFloorDB)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Text(String(format: "%.0f kHz", model.audioRate / 1000)).foregroundStyle(.secondary)
                    }.font(.caption)
                    HStack {
                        Text("聲音事件 \(model.onsetCount)")
                        Spacer()
                        if let l = model.audioLatencyMs {
                            Text(String(format: "聲音比 IMU %@ %.0f ms", l >= 0 ? "晚" : "早", abs(l)))
                        } else {
                            Text("敲一下管子來校正時間差").foregroundStyle(.secondary)
                        }
                    }.font(.caption).monospacedDigit()
                }
                Text("AirPods 麥克風會讓藍牙切到通話模式，可能影響動作資料；也可以選 Mac 內建麥克風對照。錄製 CSV 時會一起存 WAV。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { model.refreshDevices() }
        }
    }

    private var outputBox: some View {
        GroupBox("輸出") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        model.toggleRecording()
                    } label: {
                        Label(model.recording ? "停止錄製" : "錄製 CSV", systemImage: model.recording ? "stop.circle.fill" : "record.circle")
                    }
                    .tint(model.recording ? .red : nil)
                    Button("打開資料夾") { model.revealRecordings() }
                }
                if let u = model.recordURL {
                    Text(u.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Toggle(isOn: $model.udpOn) {
                    Text("UDP JSON → 127.0.0.1:\(String(model.udpPort))")
                }
                Text("Python：python3 scripts/probe_receiver.py")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logBox: some View {
        GroupBox("事件") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.log.prefix(30)) { l in
                    HStack(alignment: .top, spacing: 6) {
                        Text(l.date, format: .dateTime.hour().minute().second())
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(l.text).font(.caption)
                            .foregroundStyle(l.important ? .red : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var streamStatus: String {
        if model.inGap { return "中斷" }
        if !model.available { return "沒有支援的耳機" }
        if model.sampleCount == 0 { return model.connected ? "已連線，等資料" : "等待 AirPods" }
        return "串流中"
    }

    private var earLabel: String {
        switch model.ear {
        case .left: return "左耳"
        case .right: return "右耳"
        case .unknown: return "—"
        }
    }

    private func row(_ k: String, _ v: String, color: Color = .primary) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).foregroundStyle(color).monospacedDigit()
        }.font(.callout)
    }
}

private struct TrialCard: View {
    let trial: ProbeTrial

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(trial.index)").foregroundStyle(.secondary)
                Text("\(trial.score)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(trial.passed ? .green : .red)
                Text("分")
                Spacer()
                Text(trial.passed ? "站好了 ✓" : "沒站好 ✗")
                    .font(.headline)
                    .foregroundStyle(trial.passed ? .green : .red)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow { k("搬運時間"); v(String(format: "%.1f 秒", trial.duration)) }
                GridRow { k("最大傾斜"); v(String(format: "%.0f°", trial.maxTiltDeg)) }
                GridRow { k("最後傾斜"); v(String(format: "%.1f° %@", trial.finalTiltDeg, trial.finalState.label)) }
                GridRow { k("放下衝擊"); v(String(format: "%.2f g", trial.placeImpactG)) }
                GridRow { k("晃動 RMS"); v(String(format: "%.2f rad/s", trial.gyroRMS)) }
                if let db = trial.placeSoundDB {
                    GridRow { k("放下聲音"); v(String(format: "%.0f dBFS", db)) }
                }
                if let n = trial.carrySoundEvents {
                    GridRow { k("搬運中聲音事件"); v("\(n)") }
                }
            }
            ForEach(trial.notes, id: \.self) { n in
                Text("• " + n).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func k(_ s: String) -> some View { Text(s).font(.caption).foregroundStyle(.secondary) }
    private func v(_ s: String) -> some View { Text(s).font(.caption).monospacedDigit() }
}

private struct LevelMeter: View {
    let db: Double
    let floor: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (d: Double) in CGFloat((min(0, max(-80, d)) + 80) / 80) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, x(db)))
                Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2).offset(x: x(floor))
            }
        }
    }
}
