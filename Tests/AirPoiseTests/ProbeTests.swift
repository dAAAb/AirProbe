import XCTest
@testable import AirPoiseCore

/// Synthetic AirPod-in-a-tube streams at 25 Hz.
final class ProbeTests: XCTestCase {
    private func axisAngle(_ ax: Vec3, _ theta: Double) -> Quat {
        let a = ax.normalized
        let s = sin(theta / 2), c = cos(theta / 2)
        return Quat(x: a.x * s, y: a.y * s, z: a.z * s, w: c).normalized
    }

    /// Bud mounted with an arbitrary offset; object rotated by `objRot` in the world.
    /// convention +1: v_ref = q v_body. −1: v_body = q v_ref.
    private func sample(t: Double, objRot: Quat, mount: Quat, convention: Int = 1,
                        accel: Vec3 = .zero, gyro: Vec3 = .zero) -> ProbeSample {
        let bodyInWorld = objRot.multiplied(by: mount).normalized   // body→world
        let q = convention > 0 ? bodyInWorld : bodyInWorld.inverse
        let gBody = bodyInWorld.inverse.rotate(Vec3(0, 0, -1))
        return ProbeSample(time: t, attitude: q, gravity: gBody, userAcceleration: accel, rotationRate: gyro, ear: .left)
    }

    private let mount = Quat(x: 0.3, y: -0.5, z: 0.2, w: 0.8).normalized

    func testUprightZeroAndTilt() {
        let a = ProbeAnalyzer()
        a.zero(with: sample(t: 0, objRot: .identity, mount: mount))
        let (f0, _) = a.process(sample(t: 0.04, objRot: .identity, mount: mount))
        XCTAssertEqual(f0.tiltDeg, 0, accuracy: 0.5)
        XCTAssertEqual(f0.state, .upright)
        let (f1, _) = a.process(sample(t: 0.08, objRot: axisAngle(Vec3(1, 0, 0), Angle.rad(90)), mount: mount))
        XCTAssertEqual(f1.tiltDeg, 90, accuracy: 0.5)
        XCTAssertEqual(f1.state, .lying)
    }

    func testDisplayOrientationMatchesTiltForBothConventions() {
        for conv in [1, -1] {
            let a = ProbeAnalyzer()
            a.zero(with: sample(t: 0, objRot: .identity, mount: mount, convention: conv))
            var f: ProbeFrame!
            for i in 1...120 {
                let th = Angle.rad(Double(i) * 0.5)
                let rot = axisAngle(Vec3(1, 1, 0), th)
                f = a.process(sample(t: Double(i) * 0.04, objRot: rot, mount: mount, convention: conv)).0
            }
            XCTAssertEqual(a.convention, conv)
            let up = f.displayOrientation.rotate(Vec3(0, 1, 0))
            let shownTilt = Angle.deg(acos(Angle.clamp(up.y, -1, 1)))
            XCTAssertEqual(shownTilt, f.tiltDeg, accuracy: 1.0, "convention \(conv)")
        }
    }

    /// Lift, carry with a small tilt, set down upright → passing trial.
    func testCleanPickAndPlaceTrial() {
        let a = ProbeAnalyzer()
        a.zero(with: sample(t: 0, objRot: .identity, mount: mount))
        var t = 0.0
        var trials: [ProbeTrial] = []
        func feed(_ seconds: Double, rot: (Double) -> Quat, gyro: Double, accel: Double) {
            let n = Int(seconds * 25)
            for i in 0..<n {
                t += 0.04
                let (_, ev) = a.process(sample(t: t, objRot: rot(Double(i) / Double(n)), mount: mount,
                                                accel: Vec3(0, 0, accel), gyro: Vec3(gyro, 0, 0)))
                for e in ev { if case .trial(let tr) = e { trials.append(tr) } }
            }
        }
        feed(1, rot: { _ in .identity }, gyro: 0, accel: 0)
        feed(1.5, rot: { p in self.axisAngle(Vec3(1, 0, 0), Angle.rad(12 * sin(p * .pi))) }, gyro: 0.6, accel: 0.1)
        feed(1.5, rot: { _ in .identity }, gyro: 0, accel: 0)
        XCTAssertEqual(trials.count, 1)
        let tr = try! XCTUnwrap(trials.first)
        XCTAssertTrue(tr.passed)
        XCTAssertEqual(tr.finalState, .upright)
        XCTAssertGreaterThan(tr.score, 80)
        XCTAssertEqual(tr.maxTiltDeg, 12, accuracy: 1.5)
    }

    /// Tube tips over during placement → failed trial, capped score.
    func testTippedOverTrialFails() {
        let a = ProbeAnalyzer()
        a.zero(with: sample(t: 0, objRot: .identity, mount: mount))
        var t = 0.0
        var trials: [ProbeTrial] = []
        for i in 0..<200 {
            t += 0.04
            let moving = i >= 25 && i < 75
            let deg = moving ? Double(i - 25) / 50 * 90 : (i >= 75 ? 90 : 0)
            let (_, ev) = a.process(sample(t: t, objRot: axisAngle(Vec3(0, 1, 0), Angle.rad(deg)), mount: mount,
                                            gyro: Vec3(moving ? 0.8 : 0, 0, 0)))
            for e in ev { if case .trial(let tr) = e { trials.append(tr) } }
        }
        let tr = try! XCTUnwrap(trials.first)
        XCTAssertFalse(tr.passed)
        XCTAssertEqual(tr.finalState, .lying)
        XCTAssertLessThanOrEqual(tr.score, 30)
    }

    func testFreeFallEvent() {
        let a = ProbeAnalyzer()
        a.zero(with: sample(t: 0, objRot: .identity, mount: mount))
        var falls = 0
        for i in 0..<30 {
            var s = sample(t: Double(i) * 0.04, objRot: .identity, mount: mount)
            if (10..<16).contains(i) { s.userAcceleration = s.gravity * -0.95 }
            for e in a.process(s).1 { if case .freeFall = e { falls += 1 } }
        }
        XCTAssertEqual(falls, 1)
    }
}
