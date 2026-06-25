/// Chip variant selector for OPNChip.
public enum OPNChipType {
    case ym2203  // OPN  – 3 FM ch + SSG
    case ym2608  // OPNA – 6 FM ch + SSG
}

/// A single OPN/OPNA chip instance driven by external register writes.
///
/// Matches the fmgen_bridge call pattern used by RetroTune's S98/VGM decoders:
/// write registers from your decoder, then pull interleaved stereo Int16 PCM
/// with `render(frames:into:offset:)`. Thread safety is the caller's responsibility.
public final class OPNChip {

    private var chip: OPNA
    private let outputSampleRate: Double

    // Catmull-Rom streaming resampler state: 4-point sliding window + phase.
    private var p0L: Int32 = 0, p0R: Int32 = 0
    private var p1L: Int32 = 0, p1R: Int32 = 0
    private var p2L: Int32 = 0, p2R: Int32 = 0
    private var p3L: Int32 = 0, p3R: Int32 = 0
    private var phase: Double = 0.0

    public init(type: OPNChipType, clock: UInt32, sampleRate: Int) {
        self.chip = OPNA(clock: Double(clock))
        self.outputSampleRate = Double(sampleRate)
    }

    /// Reset all chip state (call at the start of a new track or on seek).
    public func reset() {
        chip = OPNA(clock: chip.clock)
        p0L = 0; p0R = 0
        p1L = 0; p1R = 0
        p2L = 0; p2R = 0
        p3L = 0; p3R = 0
        phase = 0.0
    }

    /// Write one register.
    /// `register` encodes port × 256 + address: port 0 = 0x000–0x0FF, port 1 = 0x100–0x1FF.
    public func writeRegister(_ register: UInt16, _ value: UInt8) {
        chip.writeRegister(port: Int(register >> 8),
                           address: UInt8(register & 0xFF),
                           data: value)
    }

    /// Render `frames` stereo interleaved Int16 samples into `buffer` starting at `offset` frames.
    /// Uses a streaming Catmull-Rom resampler to match the quality of the batch renderer.
    public func render(frames: Int, into buffer: inout [Int16], offset: Int) {
        let step = chip.sampleRate / outputSampleRate
        for i in 0..<frames {
            while phase >= 1.0 {
                p0L = p1L; p0R = p1R
                p1L = p2L; p1R = p2R
                p2L = p3L; p2R = p3R
                let s = chip.tick()
                p3L = s.0; p3R = s.1
                phase -= 1.0
            }
            let t = phase
            let l = catmullRom(Double(p0L), Double(p1L), Double(p2L), Double(p3L), t)
            let r = catmullRom(Double(p0R), Double(p1R), Double(p2R), Double(p3R), t)
            let base = (offset + i) * 2
            buffer[base]     = clampToInt16(Int32(l.rounded()))
            buffer[base + 1] = clampToInt16(Int32(r.rounded()))
            phase += step
        }
    }

    @inline(__always)
    private func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
        let c1 = (p2 - p0) * 0.5
        let c2 = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c3 = (p3 - p0) * 0.5 + 1.5 * (p1 - p2)
        return ((c3 * t + c2) * t + c1) * t + p1
    }
}
