/// A single FM operator: a phase accumulator feeding the log-domain sine tables.
///
/// This is the smallest sound-producing unit. With no extra attenuation it emits a
/// pure sine; envelope and modulation (later phases) just add into `attenuation` and
/// the phase respectively. Kept a `struct` with `@inline(__always)` hot path so the
/// per-sample loop stays ARC-free and allocation-free (see the DSP perf notes).
public struct Operator {

    /// Bits in the phase accumulator that make up one full cycle.
    /// Top `waveformBits` of these index the sine table; the rest are sub-sample phase.
    public static let phaseBits: UInt32 = 20
    /// Bits of the waveform lookup (full sine = 1024 entries: 4 × 256-entry quarter).
    public static let waveformBits: UInt32 = 10

    static let phaseMask: UInt32 = (1 << phaseBits) - 1                 // 0xFFFFF
    static let waveformShift: UInt32 = phaseBits - waveformBits          // 10
    static let waveformMask: UInt32 = (1 << waveformBits) - 1            // 0x3FF

    /// Current phase, in `[0, 2^phaseBits)`.
    public var phase: UInt32 = 0
    /// Per-sample phase advance. Set via `setFrequency` or directly for exact ratios.
    public var phaseIncrement: UInt32 = 0
    /// Extra log-domain attenuation (total level + envelope), in the same units as the
    /// sine table. `0` = full output.
    public var attenuation: UInt32 = 0

    public init() {}

    /// Set the operator's frequency for a given output sample rate.
    public mutating func setFrequency(_ hz: Double, sampleRate: Double) {
        let inc = (hz / sampleRate * Double(1 << Operator.phaseBits)).rounded()
        phaseIncrement = UInt32(inc) & Operator.phaseMask
    }

    /// Compute the signed output for a phase + attenuation, without advancing.
    ///
    /// `modulation` is a phase offset in 10-bit waveform-index units (from another
    /// operator's output or feedback); `0` is an unmodulated sine.
    @inline(__always)
    public static func sample(phase: UInt32, modulation: Int32 = 0, attenuation: UInt32) -> Int32 {
        let index = (phase >> waveformShift) &+ UInt32(bitPattern: modulation)
        let waveform = index & waveformMask // 10-bit phase, wraps with modulation
        // Low 9 bits address the |sin| half-wave; bit 9 is the sign of this half.
        let logVolume = UInt32(OpnTables.absSinAttenuation(waveform & 0x1FF)) + attenuation
        let magnitude = Int32(OpnTables.attenuationToVolume(logVolume))
        return (waveform & 0x200) != 0 ? -magnitude : magnitude
    }

    /// Advance the phase by one sample.
    @inline(__always)
    public mutating func advance() {
        phase = (phase &+ phaseIncrement) & Operator.phaseMask
    }

    /// Produce one unmodulated sample and advance the phase.
    @inline(__always)
    public mutating func next() -> Int32 {
        let out = Operator.sample(phase: phase, attenuation: attenuation)
        advance()
        return out
    }
}
