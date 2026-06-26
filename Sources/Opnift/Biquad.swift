import Foundation

/// A single biquad (RBJ cookbook) filter — the building block for the Phase 2 voicing
/// EQ. (Currently unused: the SSG anti-alias low-pass that used it was removed in favor
/// of raw point-sampling at the FM rate.)
public struct Biquad {
    private var b0: Double = 1, b1: Double = 0, b2: Double = 0
    private var a1: Double = 0, a2: Double = 0
    private var x1: Double = 0, x2: Double = 0
    private var y1: Double = 0, y2: Double = 0

    public init() {}

    /// Configure as a low-pass at `cutoff` Hz for sample rate `sampleRate`.
    public mutating func setLowpass(cutoff: Double, sampleRate: Double, q: Double = 0.70710678) {
        let w0 = 2.0 * .pi * cutoff / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2.0 * q)
        let a0 = 1.0 + alpha
        b0 = (1.0 - cosw) / 2.0 / a0
        b1 = (1.0 - cosw) / a0
        b2 = b0
        a1 = (-2.0 * cosw) / a0
        a2 = (1.0 - alpha) / a0
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// One-pole DC blocker (high-pass) — models the AC-coupled analog output. The SSG's
/// unipolar square waves carry a large DC offset (and a low-frequency "shadow" of the
/// volume envelope); real hardware removes both, which the golden renders confirm.
public struct DCBlocker {
    private var x1: Double = 0
    private var y1: Double = 0
    private var r: Double = 0.999

    public init() {}

    public mutating func configure(cutoff: Double, sampleRate: Double) {
        r = 1.0 - (2.0 * .pi * cutoff / sampleRate)
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let y = x - x1 + r * y1
        x1 = x
        y1 = y
        return y
    }
}
