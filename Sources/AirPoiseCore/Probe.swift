import Foundation

// MARK: - AirProbe: an AirPod used as an object-mounted IMU (e.g. inside a tube/can).
//
// Nothing here assumes a head. The bud sits in the object in an unknown pose, so the
// "upright" axis is learned once from gravity while the object stands still (zero()).
// Tilt is computed from gravity only (no yaw, no drift). The 3D display rotation uses
// Apple's fused attitude, with the quaternion convention verified against gravity.

public enum ProbeState: String, Codable, Sendable {
    case unknown, upright, tilted, lying, upsideDown, moving, freeFall

    public var label: String {
        switch self {
        case .unknown: return "等待資料"
        case .upright: return "直立"
        case .tilted: return "傾斜"
        case .lying: return "躺平"
        case .upsideDown: return "倒立"
        case .moving: return "移動中"
        case .freeFall: return "自由落體"
        }
    }
}

public enum ProbePhase: String, Codable, Sendable {
    case resting, carrying
}

public struct ProbeConfig: Sendable {
    /// Smoothed gyro magnitude above which the object is moving (rad/s).
    public var moveGyro = 0.30
    /// Smoothed |userAcceleration| above which the object is moving (g).
    public var moveAccel = 0.05
    /// Consecutive moving samples to start a trial (~0.12 s at 25 Hz).
    public var moveStartSamples = 3
    /// Seconds of stillness that end a trial.
    public var settleSeconds = 0.6
    /// Carry shorter than this is a bump, not a pick-and-place.
    public var minCarrySeconds = 0.4
    /// |gravity + userAcceleration| below this is free fall (g).
    public var freeFallG = 0.35
    /// |userAcceleration| spike counted as an impact (g).
    public var impactG = 0.45
    public var uprightDeg = 10.0
    public var lyingBandDeg = 20.0
    public var upsideDownDeg = 160.0

    public init() {}
}

public struct ProbeSample: Sendable {
    public var time: TimeInterval
    public var attitude: Quat
    public var gravity: Vec3
    public var userAcceleration: Vec3
    public var rotationRate: Vec3
    public var ear: SensorEar

    public init(time: TimeInterval, attitude: Quat, gravity: Vec3, userAcceleration: Vec3, rotationRate: Vec3, ear: SensorEar) {
        self.time = time
        self.attitude = attitude
        self.gravity = gravity
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.ear = ear
    }

    public init(_ s: HeadSample) {
        self.init(time: s.time, attitude: s.attitude, gravity: s.gravity,
                  userAcceleration: s.userAcceleration, rotationRate: s.rotationRate, ear: s.ear)
    }
}

public struct ProbeFrame: Sendable {
    public var time: TimeInterval
    public var tiltDeg: Double
    /// |gravity + userAcceleration| in g (≈1 at rest, ≈0 in free fall).
    public var totalG: Double
    public var accelG: Double
    public var gyro: Double
    public var state: ProbeState
    public var phase: ProbePhase
    /// Object orientation in a display frame where +Y = calibrated upright axis.
    public var displayOrientation: Quat
    public var calibrated: Bool
}

public struct ProbeTrial: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var index: Int
    public var startTime: TimeInterval
    public var duration: Double
    public var startTiltDeg: Double
    public var maxTiltDeg: Double
    public var meanTiltDeg: Double
    public var finalTiltDeg: Double
    public var finalState: ProbeState
    public var placeImpactG: Double
    public var maxAccelG: Double
    public var gyroRMS: Double
    public var freeFalls: Int
    public var score: Int
    public var passed: Bool
    public var notes: [String]
    /// Filled by the app when a mic is active (not scored): loudest sound around placement.
    public var placeSoundDB: Double? = nil
    /// Sound onsets during the carry (clinks, scrapes).
    public var carrySoundEvents: Int? = nil
}

public enum ProbeEvent: Sendable {
    case impact(time: TimeInterval, g: Double)
    case freeFall(time: TimeInterval, seconds: Double)
    case bump(time: TimeInterval)
    case trial(ProbeTrial)
}

public final class ProbeAnalyzer: @unchecked Sendable {
    public var config = ProbeConfig()

    /// Upright axis (object "up") in the bud body frame.
    public private(set) var upBody: Vec3?
    public private(set) var referenceAttitude: Quat?
    /// Body→display mapping captured at zero().
    private var bodyToDisplay: Quat = .identity
    /// +1: attitude maps body→reference (v_ref = q v_body). −1: the opposite.
    /// Decided from data by checking which convention predicts gravity.
    public private(set) var convention = 1
    private var convErrA = 0.0
    private var convErrB = 0.0
    private var g0Body: Vec3?

    public private(set) var trials: [ProbeTrial] = []
    public private(set) var phase: ProbePhase = .resting
    public private(set) var last: ProbeFrame?

    private var gyroS = 0.0
    private var accelS = 0.0
    private var movingRun = 0
    private var lastMovingTime: TimeInterval = -.infinity
    private var lastSample: ProbeSample?

    // Free fall tracking
    private var freeFallStart: TimeInterval?
    private var lastImpactTime: TimeInterval = -.infinity

    // Trial accumulators
    private var tStart: TimeInterval = 0
    private var startTilt = 0.0
    private var maxTilt = 0.0
    private var tiltSum = 0.0
    private var gyroSq = 0.0
    private var nCarry = 0
    private var maxAccel = 0.0
    private var trialFreeFalls = 0
    private var recentAccel: [(TimeInterval, Double)] = []
    private var stillTilts: [Double] = []
    private var restTilt = 0.0

    public init() {}

    public var isCalibrated: Bool { upBody != nil }

    /// Call while the object stands upright and still.
    public func zero(with sample: ProbeSample) {
        let g = sample.gravity.normalized
        guard g.length > 0.5 else { return }
        let up = g * -1
        upBody = up
        g0Body = g
        referenceAttitude = sample.attitude.normalized
        convErrA = 0; convErrB = 0
        bodyToDisplay = Self.alignment(from: up, to: Vec3(0, 1, 0))
        restTilt = 0
    }

    public func clearTrials() { trials.removeAll() }

    public func process(_ s: ProbeSample) -> (ProbeFrame, [ProbeEvent]) {
        var events: [ProbeEvent] = []
        if upBody == nil { zero(with: s) }   // provisional zero; user re-zeros upright
        lastSample = s

        let up = upBody ?? Vec3(0, 0, 1)
        let gN = s.gravity.normalized
        let c = Angle.clamp((gN * -1).dot(up), -1, 1)
        let tilt = Angle.deg(acos(c))

        let accel = s.userAcceleration.length
        let gyro = s.rotationRate.length
        let total = (s.gravity + s.userAcceleration).length
        gyroS = gyroS * 0.6 + gyro * 0.4
        accelS = accelS * 0.6 + accel * 0.4

        let movingNow = gyroS > config.moveGyro || accelS > config.moveAccel
        movingRun = movingNow ? movingRun + 1 : 0
        if movingNow { lastMovingTime = s.time }

        updateConvention(s)

        // Impact: sharp accel spike, debounced.
        recentAccel.append((s.time, accel))
        recentAccel.removeAll { s.time - $0.0 > 1.0 }
        if accel > config.impactG, s.time - lastImpactTime > 0.25 {
            lastImpactTime = s.time
            events.append(.impact(time: s.time, g: accel))
        }

        // Free fall.
        var falling = false
        if total < config.freeFallG {
            falling = true
            if freeFallStart == nil { freeFallStart = s.time }
        } else if let f = freeFallStart {
            let dur = s.time - f
            freeFallStart = nil
            if dur >= 0.05 {
                events.append(.freeFall(time: f, seconds: dur))
                if phase == .carrying { trialFreeFalls += 1 }
            }
        }

        // Trial segmentation.
        switch phase {
        case .resting:
            if movingRun >= config.moveStartSamples {
                phase = .carrying
                tStart = s.time
                startTilt = restTilt
                maxTilt = tilt; tiltSum = 0; gyroSq = 0; nCarry = 0
                maxAccel = 0; trialFreeFalls = 0; stillTilts = []
            } else if !movingNow {
                restTilt = restTilt * 0.8 + tilt * 0.2
            }
        case .carrying:
            maxTilt = max(maxTilt, tilt)
            tiltSum += tilt; gyroSq += gyro * gyro; nCarry += 1
            maxAccel = max(maxAccel, accel)
            if movingNow { stillTilts = [] } else { stillTilts.append(tilt) }
            if s.time - lastMovingTime >= config.settleSeconds {
                let carry = lastMovingTime - tStart
                if carry < config.minCarrySeconds {
                    events.append(.bump(time: tStart))
                } else {
                    let trial = finishTrial(endMoving: lastMovingTime, now: s.time)
                    trials.append(trial)
                    events.append(.trial(trial))
                }
                phase = .resting
                restTilt = stillTilts.isEmpty ? tilt : stillTilts.reduce(0, +) / Double(stillTilts.count)
            }
        }

        let state: ProbeState
        if falling { state = .freeFall }
        else if movingNow || phase == .carrying && s.time - lastMovingTime < 0.2 { state = .moving }
        else { state = classify(tilt: tilt) }

        let frame = ProbeFrame(
            time: s.time, tiltDeg: tilt, totalG: total, accelG: accel, gyro: gyro,
            state: state, phase: phase,
            displayOrientation: displayOrientation(s.attitude),
            calibrated: isCalibrated
        )
        last = frame
        return (frame, events)
    }

    public func classify(tilt: Double) -> ProbeState {
        if tilt <= config.uprightDeg { return .upright }
        if tilt >= config.upsideDownDeg { return .upsideDown }
        if abs(tilt - 90) <= config.lyingBandDeg { return .lying }
        return .tilted
    }

    // MARK: - Orientation

    /// Relative body rotation since zero(), expressed in the zeroed body frame.
    private func bodyRotation(_ q: Quat, convention c: Int) -> Quat {
        guard let r = referenceAttitude else { return .identity }
        return c > 0
            ? r.inverse.multiplied(by: q).normalized    // v_ref = q v_body
            : r.multiplied(by: q.inverse).normalized    // v_body = q v_ref
    }

    private func displayOrientation(_ q: Quat) -> Quat {
        let rb = bodyRotation(q, convention: convention)
        return bodyToDisplay.multiplied(by: rb).multiplied(by: bodyToDisplay.inverse).normalized
    }

    /// Gravity is fixed in the world, so in the body frame g_t = R⁻¹ g0. Whichever
    /// quaternion convention predicts the measured gravity better wins.
    private func updateConvention(_ s: ProbeSample) {
        guard let g0 = g0Body, referenceAttitude != nil else { return }
        let g = s.gravity.normalized
        let pa = bodyRotation(s.attitude, convention: 1).inverse.rotate(g0)
        let pb = bodyRotation(s.attitude, convention: -1).inverse.rotate(g0)
        convErrA = convErrA * 0.98 + (pa - g).length
        convErrB = convErrB * 0.98 + (pb - g).length
        if convErrB < convErrA * 0.7 { convention = -1 }
        else if convErrA < convErrB * 0.7 { convention = 1 }
    }

    /// Shortest rotation taking unit `a` to unit `b`.
    public static func alignment(from a: Vec3, to b: Vec3) -> Quat {
        let a = a.normalized, b = b.normalized
        let d = a.dot(b)
        if d > 0.999999 { return .identity }
        if d < -0.999999 {
            var axis = Vec3(1, 0, 0).cross(a)
            if axis.length < 1e-6 { axis = Vec3(0, 1, 0).cross(a) }
            axis = axis.normalized
            return Quat(x: axis.x, y: axis.y, z: axis.z, w: 0)
        }
        let c = a.cross(b)
        return Quat(x: c.x, y: c.y, z: c.z, w: 1 + d).normalized
    }

    // MARK: - Scoring

    private func finishTrial(endMoving: TimeInterval, now: TimeInterval) -> ProbeTrial {
        let finalTilt = stillTilts.isEmpty ? (last?.tiltDeg ?? 0) : stillTilts.reduce(0, +) / Double(stillTilts.count)
        let finalState = classify(tilt: finalTilt)
        // Placement impact: biggest spike in the last 0.5 s of motion (+ settle).
        let impact = recentAccel
            .filter { $0.0 >= endMoving - 0.5 && $0.0 <= endMoving + 0.3 }
            .map(\.1).max() ?? 0
        let meanTilt = nCarry > 0 ? tiltSum / Double(nCarry) : 0
        let gyroRMS = nCarry > 0 ? (gyroSq / Double(nCarry)).squareRoot() : 0

        var score = 100.0
        var notes: [String] = []
        let passed = finalState == .upright
        if !passed {
            notes.append("最後沒有站好（\(finalState.label) \(Int(finalTilt.rounded()))°）")
        }
        if maxTilt > 15 {
            let p = min(40, (maxTilt - 15) * 0.8)
            score -= p
            notes.append("搬運中最大傾斜 \(Int(maxTilt.rounded()))°  −\(Int(p.rounded()))")
        }
        if impact > 0.3 {
            let p = min(30, (impact - 0.3) * 50)
            score -= p
            notes.append(String(format: "放下衝擊 %.2f g  −%d", impact, Int(p.rounded())))
        }
        if trialFreeFalls > 0 {
            let p = Double(min(2, trialFreeFalls)) * 30
            score -= p
            notes.append("掉落 / 自由落體 ×\(trialFreeFalls)  −\(Int(p))")
        }
        if gyroRMS > 1.5 {
            let p = min(15, (gyroRMS - 1.5) * 10)
            score -= p
            notes.append(String(format: "晃動（角速度 RMS %.1f rad/s）  −%d", gyroRMS, Int(p.rounded())))
        }
        score = max(0, score)
        if !passed { score = min(score, 30) }
        if notes.isEmpty { notes.append("乾淨俐落") }

        return ProbeTrial(
            index: trials.count + 1, startTime: tStart, duration: endMoving - tStart,
            startTiltDeg: startTilt, maxTiltDeg: maxTilt, meanTiltDeg: meanTilt,
            finalTiltDeg: finalTilt, finalState: finalState, placeImpactG: impact,
            maxAccelG: maxAccel, gyroRMS: gyroRMS, freeFalls: trialFreeFalls,
            score: Int(score.rounded()), passed: passed, notes: notes
        )
    }
}
