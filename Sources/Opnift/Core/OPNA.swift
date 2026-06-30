/// YM2608 (OPNA) — register-level chip integration over six FM channels.
///
/// This wires the FM core to the Yamaha register map so a register stream (e.g. from
/// S98) can drive it: `writeRegister(port:address:data:)` then `clock()` per sample.
///
/// Scope: **FM only** for now. SSG, ADPCM-A/B, the rhythm section, timers and the LFO
/// are accepted but ignored (the addresses are decoded and dropped) so a mostly-FM
/// stream plays. CH3 special (per-operator frequency) mode and detune are not yet
/// modeled. These are deliberate Phase-5 omissions, not bugs.
///
/// Frequency: at the native FM rate `clock / fmDivider` (~55466 Hz; OPNA/YM2608 =
/// clock/144, OPN/YM2203 = clock/72), a 20-bit phase accumulator advances by
/// `(fnum << block) >> 1` per sample (derived to match A440 ≈ block 4 / fnum 0x410).
/// Per-operator MUL scales that.
/// Which OPN-family chip is being emulated. The single chip-selector type across the
/// library: parsers, `ChipVoice`, and `OPNA` all speak `ChipKind`.
public enum ChipKind { case opn /* YM2203 */, opna /* YM2608 */ }

public struct OPNA {

    /// Default OPNA master clock (Hz).
    public static let defaultClock: Double = 7_987_200
    /// Default OPNA master clock as an integer (Hz).
    public static let defaultClockHz: UInt32 = 7_987_200

    public let clock: Double
    /// The modeled chip family.
    public let kind: ChipKind
    /// FM clock divider: OPN (YM2203) runs the FM engine at master/72, OPNA (YM2608) at
    /// master/144. Both land near 55.5 kHz since OPNA's master clock is ~2× the OPN's.
    private var fmDivider: Double { kind == .opn ? 72.0 : 144.0 }
    /// Native FM synthesis sample rate (Hz).
    public var sampleRate: Double { clock / fmDivider }

    public var channels: [FMChannel]
    /// The SSG (square-wave) side of the chip.
    public var ssg = SSG()
    /// SSG → FM mix level. 0.5 normalizes the SSG's 14-bit amplitude table down to the
    /// FM operators' 13-bit range, which matches the golden FM:SSG balance (gain ≈ 0 dB).
    public var ssgVolume: Double = 0.5
    /// FM mix level (1 = normal). Mainly for isolating SSG vs FM during analysis.
    public var fmVolume: Double = 1.0

    /// SSG/FM clock ratio is 18:1 on both chips (OPNA: master/8 ÷ master/144;
    /// OPN: master/4 ÷ master/72), so this constant is correct regardless of kind.
    private static let ssgClocksPerSample = 18
    // AC-couple the final output (the chip's analog output is DC-blocked).
    private var dcBlockL = DCBlocker()
    private var dcBlockR = DCBlocker()

    // Per-channel pitch state.
    private var blockFnumHigh: [UInt8] // latched 0xA4 (block + fnum high bits)
    private var fnum: [UInt16]
    private var block: [UInt8]
    // Per-operator key-scale field (KS, 0…3) for rate scaling.
    private var keyScaleField: [[UInt8]]
    // Per-operator detune field (DT, 0…7: bit 2 = sign, bits 0–1 = amount).
    private var detuneField: [[UInt8]]
    // Stereo enables per channel.
    public private(set) var panLeft: [Bool]
    public private(set) var panRight: [Bool]

    // EG runs at fs/3 on real OPN.
    private var egDivider: Int = 0
    private var egCounter: UInt32 = 0

    /// Register address offset → logical operator. Yamaha addresses operators in the
    /// slot order S1, S3, S2, S4.
    private static let slotToOperator: [Int] = [0, 2, 1, 3]
    /// F-Number top-nibble → key-code low bits (OPN key-scaling table).
    private static let fkTable: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3]

    /// Detune table `[amount 0…3][keycode 0…31]`: phase-increment offset in our 20-bit
    /// phase units. The values are the canonical Yamaha `dt_tab` from MAME (via ymfm);
    /// the key-code/KSR logic is likewise ported from ymfm. BSD-3-Clause; see THIRD_PARTY.
    private static let detuneTable: [UInt8] = [
        // amount 0 (no detune)
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        // amount 1
        0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2,
        2, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 8, 8, 8, 8,
        // amount 2
        1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5,
        5, 6, 6, 7, 8, 8, 9, 10, 11, 12, 13, 14, 16, 16, 16, 16,
        // amount 3
        2, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7,
        8, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 20, 22, 22, 22, 22,
    ]

    public init(clock: Double = OPNA.defaultClock, kind: ChipKind = .opna) {
        self.clock = clock
        self.kind = kind
        channels = (0..<6).map { _ in FMChannel() }
        blockFnumHigh = Array(repeating: 0, count: 6)
        fnum = Array(repeating: 0, count: 6)
        block = Array(repeating: 0, count: 6)
        keyScaleField = Array(repeating: [0, 0, 0, 0], count: 6)
        detuneField = Array(repeating: [0, 0, 0, 0], count: 6)
        panLeft = Array(repeating: true, count: 6)
        panRight = Array(repeating: true, count: 6)

        dcBlockL.configure(cutoff: 10, sampleRate: sampleRate)
        dcBlockR.configure(cutoff: 10, sampleRate: sampleRate)
    }

    // MARK: Register write

    /// Write one chip register. `port` 0 drives channels 1–3, port 1 drives 4–6.
    public mutating func writeRegister(port: Int, address: UInt8, data: UInt8) {
        // Key on/off is a global, port-0 register that carries its own channel select.
        if port == 0 && address == 0x28 {
            keyOnOff(data)
            return
        }
        // SSG registers (port 0, 0x00–0x0F).
        if port == 0 && address < 0x10 {
            ssg.writeRegister(address, data)
            return
        }
        // Timer / LFO / prescaler / ADPCM live below 0x30 — decoded but ignored.
        if address < 0x30 { return }

        let column = Int(address & 0x03)
        if column == 3 { return } // 0xX3 / 0xX7 are not valid channel columns
        let ch = port * 3 + column

        switch address & 0xF0 {
        case 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90:
            writeOperatorRegister(channel: ch, address: address, data: data)
        case 0xA0:
            writePitchRegister(channel: ch, address: address, data: data)
        case 0xB0:
            writeChannelRegister(channel: ch, address: address, data: data)
        default:
            break
        }
    }

    private mutating func writeOperatorRegister(channel ch: Int, address: UInt8, data: UInt8) {
        let op = OPNA.slotToOperator[Int((address >> 2) & 0x03)]
        switch address & 0xF0 {
        case 0x30: // DT / MUL
            channels[ch].multiple[op] = data & 0x0F
            detuneField[ch][op] = (data >> 4) & 0x07
            updatePitch(ch)
        case 0x40: // TL
            channels[ch].totalLevel[op] = data & 0x7F
        case 0x50: // KS / AR
            keyScaleField[ch][op] = (data >> 6) & 0x03
            channels[ch].envelopes[op].attackRate = data & 0x1F
            updateKeyScale(ch, op)
        case 0x60: // AM / D1R
            channels[ch].envelopes[op].decayRate = data & 0x1F
        case 0x70: // D2R
            channels[ch].envelopes[op].sustainRate = data & 0x1F
        case 0x80: // SL / RR
            channels[ch].envelopes[op].releaseRate = data & 0x0F
            channels[ch].envelopes[op].sustainLevel = (data >> 4) & 0x0F
        default: // 0x90 SSG-EG — not modeled
            break
        }
    }

    private mutating func writePitchRegister(channel ch: Int, address: UInt8, data: UInt8) {
        switch address & 0x0C {
        case 0x00: // 0xA0–0xA2: F-Number low → commit pitch using latched high
            fnum[ch] = (UInt16(blockFnumHigh[ch] & 0x07) << 8) | UInt16(data)
            block[ch] = (blockFnumHigh[ch] >> 3) & 0x07
            updatePitch(ch)
        case 0x04: // 0xA4–0xA6: Block + F-Number high → latch only
            blockFnumHigh[ch] = data
        default: // 0xA8–0xAE: CH3 special mode — not modeled
            break
        }
    }

    private mutating func writeChannelRegister(channel ch: Int, address: UInt8, data: UInt8) {
        switch address & 0x0C {
        case 0x00: // 0xB0–0xB2: feedback / algorithm
            channels[ch].algorithm = data & 0x07
            channels[ch].feedback = (data >> 3) & 0x07
        case 0x04: // 0xB4–0xB6: L / R / AMS / PMS
            panLeft[ch] = (data & 0x80) != 0
            panRight[ch] = (data & 0x40) != 0
        default:
            break
        }
    }

    private mutating func keyOnOff(_ data: UInt8) {
        let select = Int(data & 0x07)
        // 0,1,2 → channels 0–2; 4,5,6 → channels 3–5.
        guard (select & 0x03) != 3 else { return }
        let ch = (select & 0x03) + ((select & 0x04) != 0 ? 3 : 0)
        channels[ch].setKeyState(slots: data >> 4)
    }

    // MARK: Pitch helpers

    private mutating func updatePitch(_ ch: Int) {
        let base = Int32((UInt32(fnum[ch]) << block[ch]) >> 1)
        let keycode = Int((UInt8(block[ch]) << 2) | OPNA.fkTable[Int(fnum[ch] >> 7)])
        for op in 0..<4 {
            // Detune nudges the phase increment a few units around the base frequency.
            let field = detuneField[ch][op]
            let detune = Int32(OPNA.detuneTable[Int(field & 3) * 32 + keycode])
            let detuned = max((field & 4) != 0 ? base - detune : base + detune, 0)
            // MUL multiplies after detune (MUL 0 means ×0.5).
            let mul = channels[ch].multiple[op]
            let inc = (mul == 0) ? (UInt32(detuned) >> 1) : (UInt32(detuned) &* UInt32(mul))
            channels[ch].operators[op].phaseIncrement = inc & Operator.phaseMask
            updateKeyScale(ch, op)
        }
    }

    private mutating func updateKeyScale(_ ch: Int, _ op: Int) {
        let keycode = (UInt8(block[ch]) << 2) | OPNA.fkTable[Int(fnum[ch] >> 7)]
        let ks = keyScaleField[ch][op]
        channels[ch].envelopes[op].keyScale = keycode >> (3 - ks)
    }

    // MARK: Clock

    /// Produce one stereo sample. L/R are unscaled sums (mixing/clamping is Phase 6).
    public mutating func tick() -> (left: Int32, right: Int32) {
        egDivider += 1
        if egDivider >= 3 {
            egDivider = 0
            egCounter &+= 1
            for ch in 0..<6 { channels[ch].clockEnvelopes(egCounter) }
        }

        var left: Int32 = 0
        var right: Int32 = 0
        for ch in 0..<6 {
            let sample = channels[ch].next()
            if panLeft[ch] { left &+= sample }
            if panRight[ch] { right &+= sample }
        }
        if fmVolume != 1.0 {
            left = Int32(Double(left) * fmVolume)
            right = Int32(Double(right) * fmVolume)
        }

        // SSG runs at 18× the FM rate. Average its output over those sub-clocks (a
        // boxcar decimation filter) rather than point-sampling once: point-sampling the
        // clock/144 native rate folds the SSG square-wave harmonics into the audible
        // band. That's tolerable on OPNA-clock files (native ~55.5 kHz, Nyquist 27.7 kHz)
        // but on low-clock YM2149 files (native ~27.7 kHz, Nyquist 13.9 kHz) the folded
        // harmonics land mid-band as an audible metallic ring (e.g. a +25 dB spur near
        // 6.9 kHz vs the fmgen golden). The boxcar nulls the harmonics at multiples of
        // the sub-clock rate and cheaply band-limits before we sample at the FM rate.
        var ssgAccum: Int32 = 0
        for _ in 0..<OPNA.ssgClocksPerSample {
            ssg.clock()
            ssgAccum &+= ssg.output()
        }
        let ssgSample = Int32(Double(ssgAccum) / Double(OPNA.ssgClocksPerSample) * ssgVolume)
        left &+= ssgSample
        right &+= ssgSample

        // AC-couple (remove the SSG's DC offset / envelope shadow), like the real output.
        left = Int32(dcBlockL.process(Double(left)))
        right = Int32(dcBlockR.process(Double(right)))
        return (left, right)
    }
}
