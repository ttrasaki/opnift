import Foundation

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
