import Foundation

/// Makes short speech clips as loud as possible *within* full scale:
/// high-pass (tiny out-of-ear driver can't do bass) → presence boost → compressor with
/// makeup gain → soft clipper → peak normalize. Mono Float32 in, mono Float32 out.
enum LoudSpeech {
    struct Settings {
        var driveDB: Double = 20        // makeup gain into the compressor/limiter
        var lookaheadMs: Double = 4
        var thresholdDB: Double = -24
        var ratio: Double = 4
        var attackMs: Double = 3
        var releaseMs: Double = 80
        var highpassHz: Double = 180
        var presenceHz: Double = 3000
        var presenceDB: Double = 5
        var ceiling: Float = 0.97       // ≈ −0.3 dBFS
    }

    struct Stats {
        var rmsBeforeDB: Double
        var rmsAfterDB: Double
        var peakBeforeDB: Double
        var peakAfterDB: Double
        var gainDB: Double { rmsAfterDB - rmsBeforeDB }
    }

    static func process(_ x: [Float], sampleRate sr: Double, settings s: Settings = Settings()) -> [Float] {
        guard !x.isEmpty, sr > 0 else { return x }
        var y = x
        var hp = Biquad.highpass(fc: s.highpassHz, q: 0.707, sr: sr)
        var pk = Biquad.peaking(fc: s.presenceHz, q: 1.0, gainDB: s.presenceDB, sr: sr)
        for i in y.indices { y[i] = pk.run(hp.run(y[i])) }

        // Normalize the filtered signal to full scale before compression.
        let p0 = y.map { abs($0) }.max() ?? 0
        if p0 > 1e-6 { let k = 1 / p0; for i in y.indices { y[i] *= k } }

        // Feed-forward compressor (peak envelope, hard knee) + makeup gain, with lookahead:
        // the gain for sample i comes from the envelope `lookahead` samples later, so the
        // gain is already down when a transient arrives (no onset overshoot into the clipper).
        let aA = exp(-1 / (s.attackMs * 0.001 * sr))
        let aR = exp(-1 / (s.releaseMs * 0.001 * sr))
        let makeup = pow(10, s.driveDB / 20)
        let look = max(0, Int(s.lookaheadMs * 0.001 * sr))
        var env = [Double](repeating: 0, count: y.count)
        var e = 0.0
        for i in y.indices {
            let v = Double(abs(y[i]))
            e = v > e ? aA * e + (1 - aA) * v : aR * e + (1 - aR) * v
            env[i] = e
        }
        for i in y.indices {
            var ePeak = env[i]
            if look > 0 { for j in i...min(y.count - 1, i + look) where env[j] > ePeak { ePeak = env[j] } }
            let lvl = 20 * log10(max(ePeak, 1e-6))
            let over = lvl - s.thresholdDB
            let grDB = over > 0 ? -over * (1 - 1 / s.ratio) : 0
            y[i] = Float(Double(y[i]) * pow(10, grDB / 20) * makeup)
        }

        // Soft clip: bounded by the ceiling, nearly linear for small signals.
        let c = s.ceiling
        for i in y.indices { y[i] = c * tanhf(y[i] / c) }
        let p1 = y.map { abs($0) }.max() ?? 0
        if p1 > 1e-6 { let k = c / p1; for i in y.indices { y[i] *= k } }
        return y
    }

    /// Loudness over the voiced part only (frames above −50 dBFS), so silence doesn't skew it.
    static func stats(before x: [Float], after y: [Float], sampleRate sr: Double) -> Stats {
        Stats(rmsBeforeDB: gatedRMS(x, sr), rmsAfterDB: gatedRMS(y, sr),
              peakBeforeDB: peakDB(x), peakAfterDB: peakDB(y))
    }

    static func peakDB(_ x: [Float]) -> Double {
        20 * log10(max(Double(x.map { abs($0) }.max() ?? 0), 1e-9))
    }

    static func gatedRMS(_ x: [Float], _ sr: Double) -> Double {
        let hop = max(64, Int(sr * 0.02))
        var sum = 0.0, n = 0
        var i = 0
        while i < x.count {
            let m = min(hop, x.count - i)
            var e = 0.0
            for k in 0..<m { e += Double(x[i + k] * x[i + k]) }
            if 10 * log10(max(e / Double(m), 1e-12)) > -50 { sum += e; n += m }
            i += m
        }
        return n > 0 ? 10 * log10(sum / Double(n)) : -120
    }
}

/// RBJ cookbook biquad, transposed direct form II.
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0

    mutating func run(_ x: Float) -> Float {
        let xd = Double(x)
        let y = b0 * xd + z1
        z1 = b1 * xd - a1 * y + z2
        z2 = b2 * xd - a2 * y
        return Float(y)
    }

    static func highpass(fc: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * .pi * fc / sr, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - al) / a0)
    }

    static func peaking(fc: Double, q: Double, gainDB: Double, sr: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * fc / sr, c = cos(w), al = sin(w) / (2 * q)
        let a0 = 1 + al / A
        return Biquad(b0: (1 + al * A) / a0, b1: -2 * c / a0, b2: (1 - al * A) / a0,
                      a1: -2 * c / a0, a2: (1 - al / A) / a0)
    }
}
