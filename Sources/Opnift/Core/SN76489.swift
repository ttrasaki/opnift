import Foundation

/// SN76489 (DCSG) — the Sega Master System / Mega Drive PSG: three square-wave tone
/// channels plus one noise channel, each with a 4-bit attenuator (2 dB per step).
///
/// Register model (one write port; a latch byte selects the target register):
/// - `1cct dddd` latches channel `cc` / type `t` (1 = volume) and writes the low 4 bits.
/// - `0?dd dddd` writes the remaining high bits of the latched register (tone periods
///   are 10-bit; volume/noise re-write their 4/3 bits).
///
/// Timing: tone/noise counters count down at master/16. A tone counter reload toggles
/// the channel's square output; the noise counter clocks a 16-bit LFSR (taps 0x0009 in
/// white mode — the Sega integrated variant). `tick()` emits at master/64, averaging
/// 4 sub-clocks (a boxcar), mirroring the OPNA SSG path: it nulls the square-wave
/// harmonics before the Catmull-Rom resampler point-samples the stream.
///
/// Written from the SMS Power! SN76489 hardware notes (register/LFSR behaviour is
/// public documentation; no emulator code was copied).
public struct SN76489: FMCore {

    /// Default master clock (Hz) — the NTSC colorburst rate used by SMS/MD.
    public static let defaultClock: Double = 3_579_545

    public let clock: Double
    /// Output rate of `tick()`: master/64 (~55.9 kHz), in the same band as the FM cores.
    public var sampleRate: Double { clock / 64.0 }

    /// Overall PSG level. The chip has no FM/SSG split; this maps the shared
    /// `ssgVolume` control (`SSG_VOLUME` env) onto the whole chip.
    public var ssgVolume: Double = 1.0
    /// Unused — the SN76489 has no FM section; stored only to satisfy `FMCore`.
    public var fmVolume: Double = 1.0

    /// Attenuator value → linear amplitude, 2 dB per step; 15 is silence. Full scale
    /// (4096) is half an FM channel's ±8168 so the PSG sits under the FM mix, roughly
    /// the hardware balance.
    private static let volumeTable: [Int32] = (0..<16).map {
        $0 == 15 ? 0 : Int32((4096.0 * pow(10.0, -Double($0) / 10.0)).rounded())
    }

    // Latched register selector (set by a `1cctdddd` byte, used by data bytes).
    private var latchedChannel = 0
    private var latchedIsVolume = false

    private var tonePeriod: [Int32] = [0, 0, 0]       // 10-bit reload values
    private var volume: [UInt8] = [15, 15, 15, 15]    // ch 0–2 tone, 3 noise; 15 = mute
    private var noiseControl: UInt8 = 0               // bit 2 = white, bits 0–1 = rate

    private var toneCounter: [Int32] = [0, 0, 0]
    private var toneOutput: [Bool] = [true, true, true]
    private var noiseCounter: Int32 = 0
    private var lfsr: UInt16 = 0x8000

    // The chip's unipolar output is AC-coupled on the board; do the same so a stuck
    // tone (period 0 = constant high, the PCM-playback trick) doesn't leave DC.
    private var dcBlock = DCBlocker()

    public init(clock: Double = SN76489.defaultClock) {
        self.clock = clock
        dcBlock.configure(cutoff: 10, sampleRate: sampleRate)
    }

    // MARK: Register write

    /// Write one command byte (`port`/`address` are ignored — the chip has one port).
    public mutating func writeRegister(port: Int, address: UInt8, data: UInt8) {
        write(data)
    }

    /// Write one command byte to the chip.
    public mutating func write(_ data: UInt8) {
        if data & 0x80 != 0 { // latch + low bits
            latchedChannel = Int((data >> 5) & 0x03)
            latchedIsVolume = (data & 0x10) != 0
            if latchedIsVolume {
                volume[latchedChannel] = data & 0x0F
            } else if latchedChannel < 3 {
                tonePeriod[latchedChannel] =
                    (tonePeriod[latchedChannel] & 0x3F0) | Int32(data & 0x0F)
            } else {
                setNoiseControl(data)
            }
        } else { // data byte: high bits of the latched register
            if latchedIsVolume {
                volume[latchedChannel] = data & 0x0F
            } else if latchedChannel < 3 {
                tonePeriod[latchedChannel] =
                    (Int32(data & 0x3F) << 4) | (tonePeriod[latchedChannel] & 0x00F)
            } else {
                setNoiseControl(data)
            }
        }
    }

    private mutating func setNoiseControl(_ data: UInt8) {
        noiseControl = data & 0x07
        lfsr = 0x8000 // any noise-register write resets the shift register
    }

    // MARK: Clock

    /// LFSR shift interval in master/16 sub-clocks: rates 0–2 are fixed (master/512,
    /// /1024, /2048); rate 3 tracks tone 2 (one shift per full tone-2 cycle).
    private var noiseReload: Int32 {
        switch noiseControl & 0x03 {
        case 0: return 32
        case 1: return 64
        case 2: return 128
        default: return 2 * max(tonePeriod[2], 1)
        }
    }

    /// Advance one master/16 sub-clock and return the summed channel output.
    private mutating func subClock() -> Int32 {
        for ch in 0..<3 {
            // Period 0 never reloads-and-toggles: the output sticks high (real chip
            // behaviour, used for volume-register PCM playback).
            guard tonePeriod[ch] != 0 else { toneOutput[ch] = true; continue }
            toneCounter[ch] -= 1
            if toneCounter[ch] <= 0 {
                toneCounter[ch] = tonePeriod[ch]
                toneOutput[ch].toggle()
            }
        }

        noiseCounter -= 1
        if noiseCounter <= 0 {
            noiseCounter = noiseReload
            // White noise taps bits 0 and 3 (0x0009); periodic feeds bit 0 straight back.
            let bit0 = lfsr & 1
            let feedback = (noiseControl & 0x04) != 0 ? bit0 ^ ((lfsr >> 3) & 1) : bit0
            lfsr = (lfsr >> 1) | (feedback << 15)
        }

        var sum: Int32 = 0
        for ch in 0..<3 {
            let amp = SN76489.volumeTable[Int(volume[ch])]
            sum &+= toneOutput[ch] ? amp : -amp
        }
        let noiseAmp = SN76489.volumeTable[Int(volume[3])]
        sum &+= (lfsr & 1) != 0 ? noiseAmp : -noiseAmp
        return sum
    }

    /// Produce one mono-as-stereo sample at master/64 (4 sub-clocks, boxcar-averaged).
    public mutating func tick() -> (left: Int32, right: Int32) {
        var accum: Int32 = 0
        for _ in 0..<4 { accum &+= subClock() }
        let sample = Int32(dcBlock.process(Double(accum) / 4.0 * ssgVolume))
        return (sample, sample)
    }
}
