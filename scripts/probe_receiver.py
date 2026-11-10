#!/usr/bin/env python3
"""Receive AirProbe's UDP JSON stream (enable "UDP JSON" in the app).

Message types:
  sample   ~25 Hz: t, host, ear, q[xyzw], g[xyz] (gravity, g), a[xyz] (user accel, g),
           w[xyz] (rad/s), tilt (deg from zeroed upright), total_g, state, phase, q_display
  impact   t, g
  freefall t, seconds
  trial    a scored pick-and-place (score, passed, maxTiltDeg, finalTiltDeg, placeImpactG, notes…)

Usage:  python3 scripts/probe_receiver.py [--port 9870] [--quiet]
Hook your robot loop into on_sample / on_trial below.
"""
import argparse, json, socket, sys, time


def on_sample(m):
    pass  # e.g. abort a place if m["state"] == "freeFall"


def on_trial(m):
    pass  # e.g. log m["passed"], m["score"] next to the LeRobot episode id


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9870)
    ap.add_argument("--quiet", action="store_true", help="only print events, not the live line")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", args.port))
    print(f"listening on udp://127.0.0.1:{args.port}  (Ctrl-C to stop)")
    n, t0 = 0, time.time()
    while True:
        m = json.loads(sock.recv(65536))
        kind = m.get("type")
        if kind == "sample":
            n += 1
            on_sample(m)
            if not args.quiet:
                hz = n / max(1e-6, time.time() - t0)
                sys.stdout.write(f"\r{m['state']:>10}  tilt {m['tilt']:6.1f}°  |g| {m['total_g']:.2f}  "
                                 f"ear {m['ear']:<5} {hz:4.1f} Hz   ")
                sys.stdout.flush()
        elif kind == "trial":
            on_trial(m)
            mark = "PASS" if m["passed"] else "FAIL"
            print(f"\n[trial #{m['index']}] {mark} {m['score']} 分  max tilt {m['maxTiltDeg']:.0f}°  "
                  f"final {m['finalTiltDeg']:.1f}°  impact {m['placeImpactG']:.2f} g  | {'; '.join(m['notes'])}")
        elif kind == "impact":
            print(f"\n[impact] {m['g']:.2f} g")
        elif kind == "freefall":
            print(f"\n[free fall] {m['seconds']:.2f} s")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
