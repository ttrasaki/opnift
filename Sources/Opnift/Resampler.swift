import Foundation

/// Streaming stereo Catmull-Rom resampler from a native input rate to an output rate.
///
/// This is the single source of truth for rate conversion in Opnift. It keeps the
/// fractional phase and a 4-point sliding window across calls, so feeding it in
/// arbitrary-sized chunks produces exactly the same result as one continuous pass —
/// no per-block phase reset, edge clamping, or dropped samples (the artifacts that
/// the old batch `resampleLinear`-per-block usage produced as constant crackle).
///
/// Native frames are pulled on demand through a caller-supplied closure, so the
/// resampler never needs the whole input buffered; it asks for the next native
/// frame only when its phase advances past one.
public struct Resampler {

    /// Input frames consumed per output frame (= inputRate / outputRate).
    private let step: Double

    // 4-point sliding window (most recent native frames), per channel.
    private var p0L: Int32 = 0, p0R: Int32 = 0
    private var p1L: Int32 = 0, p1R: Int32 = 0
    private var p2L: Int32 = 0, p2R: Int32 = 0
    private var p3L: Int32 = 0, p3R: Int32 = 0
    private var phase: Double = 0.0

    public init(inputRate: Double, outputRate: Double) {
        self.step = inputRate / outputRate
    }

    /// Clear the window and phase. Call at the start of a new track or on seek.
    public mutating func reset() {
        p0L = 0; p0R = 0
        p1L = 0; p1R = 0
        p2L = 0; p2R = 0
        p3L = 0; p3R = 0
        phase = 0.0
    }

    /// Produce one output frame, pulling native frames via `next` as the phase requires.
    @inline(__always)
    public mutating func render(_ next: () -> (Int32, Int32)) -> (left: Int32, right: Int32) {
        while phase >= 1.0 {
            p0L = p1L; p0R = p1R
            p1L = p2L; p1R = p2R
            p2L = p3L; p2R = p3R
            let s = next()
            p3L = s.0; p3R = s.1
            phase -= 1.0
        }
        let t = phase
        let l = Resampler.catmullRom(Double(p0L), Double(p1L), Double(p2L), Double(p3L), t)
        let r = Resampler.catmullRom(Double(p0R), Double(p1R), Double(p2R), Double(p3R), t)
        phase += step
        return (Int32(l.rounded()), Int32(r.rounded()))
    }

    @inline(__always)
    private static func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
        let c1 = (p2 - p0) * 0.5
        let c2 = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c3 = (p3 - p0) * 0.5 + 1.5 * (p1 - p2)
        return ((c3 * t + c2) * t + c1) * t + p1
    }
}
