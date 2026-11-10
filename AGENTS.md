# AirPoise

macOS 14+ menu-bar utility. Reads AirPods IMU via `CMHeadphoneMotionManager`.

## Build

```
./scripts/build-app.sh
open dist/AirPoise.app
```

Always run the `.app` (Info.plist carries `NSMotionUsageDescription`).

```
swift test --package-path .
swift build -c release --product AirPoise
```

## Layout

- `Sources/AirPoiseCore` — math, pose, gesture engine, posture coach, settings store. No AppKit.
- `Sources/AirPoise` — menu bar, overlays, action runner, SwiftUI settings.
- `Tests/AirPoiseTests` — math / posture / gesture / probe unit tests.
- `Sources/AirProbe` + `AirPoiseCore/Probe.swift` — AirProbe.app: AirPod as an object-mounted IMU (活萃力 tube demo). Build: `./scripts/build-probe.sh`. See `docs/AirProbe.md`.

## Motion rules

- Do not invent a second AHRS. Consume Apple's fused `CMDeviceMotion`.
- **Headphone body frame: x = right ear, y = nose, z = crown** (not the iPhone frame). Euler convention lives in `Quat.headphoneEuler`; gyro: turn = ωz, nod = ωx, tilt = ωy.
- Posture = gravity vs calibrated upright. Gestures = excursions from a slow rest pose.
- Resubscribe on wake / silent stream. Don't stack `startDeviceMotionUpdates` handlers.
