/// A single OPN/OPNA chip plus its streaming resampler, rendering at the output rate.
///
/// Write registers from your decoder/player, then pull interleaved stereo Int16 PCM
/// with `render(frames:into:offset:)`. The native chip rate is fully internal: callers
/// only ever see `outputSampleRate`. Native-rate samples are pulled on demand by the
/// `Resampler`, so rendering in arbitrary chunk sizes is seamless (no block artifacts).
///
/// Thread safety is the caller's responsibility.
public final class ChipVoice {

    private var chip: OPNA
    private var resampler: Resampler
    private let outputSampleRate: Double

    public init(kind: ChipKind, clock: UInt32, sampleRate: Int) {
        self.chip = OPNA(clock: Double(clock), kind: kind)
        self.outputSampleRate = Double(sampleRate)
        self.resampler = Resampler(inputRate: chip.sampleRate, outputRate: Double(sampleRate))
    }

    /// Reset all chip and resampler state (call at the start of a new track or on seek).
    public func reset() {
        chip = OPNA(clock: chip.clock, kind: chip.kind)
        resampler.reset()
    }

    /// SSG → FM mix level passthrough (see `OPNA.ssgVolume`).
    public var ssgVolume: Double {
        get { chip.ssgVolume }
        set { chip.ssgVolume = newValue }
    }

    /// FM mix level passthrough (see `OPNA.fmVolume`).
    public var fmVolume: Double {
        get { chip.fmVolume }
        set { chip.fmVolume = newValue }
    }

    /// Write one register.
    /// `register` encodes port × 256 + address: port 0 = 0x000–0x0FF, port 1 = 0x100–0x1FF.
    public func writeRegister(_ register: UInt16, _ value: UInt8) {
        chip.writeRegister(port: Int(register >> 8),
                           address: UInt8(register & 0xFF),
                           data: value)
    }

    /// Write one register by explicit port/address.
    public func writeRegister(port: Int, address: UInt8, data: UInt8) {
        chip.writeRegister(port: port, address: address, data: data)
    }

    /// Render `frames` stereo interleaved Int16 frames into `buffer` starting at `offset` frames.
    public func render(frames: Int, into buffer: inout [Int16], offset: Int) {
        for i in 0..<frames {
            let (l, r) = resampler.render { chip.tick() }
            let base = (offset + i) * 2
            buffer[base]     = clampToInt16(l)
            buffer[base + 1] = clampToInt16(r)
        }
    }

    /// Render `frames` stereo frames, *adding* the unclamped Int32 result into `mix`
    /// (interleaved) starting at `offset` frames. Used to sum multiple chips before clamp.
    public func renderAdditive(frames: Int, into mix: inout [Int32], offset: Int) {
        for i in 0..<frames {
            let (l, r) = resampler.render { chip.tick() }
            let base = (offset + i) * 2
            mix[base]     &+= l
            mix[base + 1] &+= r
        }
    }
}
