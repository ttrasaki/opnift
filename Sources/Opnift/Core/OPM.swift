import Foundation

/// YM2151 (OPM) — register-level chip integration over eight FM channels.
///
/// The OPM shares the OPN family's 4-operator FM engine (`FMChannel` / `Operator` /
/// `EnvelopeGenerator` / `OpnTables`), so this type is mostly a register-map adapter plus
/// the OPM-specific pitch math. It is what X68000 music (VGM cmd 0x54 / S98 device type 5)
/// drives: `writeRegister(...)` then `tick()` per sample.
///
/// Scope: **FM only**. The LFO (PM/AM — regs 0x18/0x19/0x1B and per-channel PMS/AMS at
/// 0x38), the noise generator (0x0F), timers and the CT output pins are decoded and
/// dropped, mirroring how `OPNA` ships without its LFO. Pitch modulation written directly
/// as KC/KF still works; only the hardware LFO sweep is absent. This is a deliberate first
/// increment to be tuned against the fmgen golden, not a bug.
///
/// ## Pitch / clock
/// The OPM derives pitch from a 7-bit **key code** (KC: octave + note) and a 6-bit **key
/// fraction** (KF), not OPN's f-num/block. The phase increment the chip computes from KC/KF
/// is *clock-independent*; the audible frequency is `increment × (clock/64) / 2^20`. So the
/// increment is built against a fixed **nominal** OPM rate (3.579545 MHz / 64) and the real
/// clock then scales the output — e.g. an X68000 4 MHz OPM plays ~1.9 semitones sharp, just
/// like the real hardware. The note table is calibrated so octave-4 "A" (KC note index 8,
/// i.e. KC=0x4A) is 440 Hz at the nominal clock.
public struct OPM: FMCore {

    /// Default OPM master clock (Hz) — the X68000 / common YM2151 rate.
    public static let defaultClock: Double = 4_000_000
    /// Default OPM master clock as an integer (Hz).
    public static let defaultClockHz: UInt32 = 4_000_000

    /// Rate the KC/KF → phase-increment table is calibrated against (the nominal 3.579545 MHz
    /// OPM, FM rate = clock/64). The real clock scales the audible pitch relative to this.
    private static let nominalSampleRate: Double = 3_579_545.0 / 64.0

    public let clock: Double
    /// Native FM synthesis sample rate (Hz): the OPM runs its FM engine at master/64.
    public var sampleRate: Double { clock / 64.0 }

    public var channels: [FMChannel]
    public var fmVolume: Double = 1.0
    /// OPM has no SSG; this passthrough exists only to satisfy `FMCore`.
    public var ssgVolume: Double { get { 0 } set { _ = newValue } }

    // Per-channel pitch state.
    private var keyCode: [UInt8]      // 0x28–0x2F: 7-bit KC (octave + note)
    private var keyFraction: [UInt8]  // 0x30–0x37: 6-bit KF (from data bits 7…2)
    // Per-operator detune/scale fields.
    private var dt1Field: [[UInt8]]      // 0x40 bits 6…4 (fine detune: bit2 = sign)
    private var dt2Field: [[UInt8]]      // 0xC0 bits 7…6 (coarse detune)
    private var keyScaleField: [[UInt8]] // 0x80 bits 7…6 (KS, rate scaling)

    public private(set) var panLeft: [Bool]
    public private(set) var panRight: [Bool]

    // EG runs at fs/3, as on OPN.
    private var egDivider: Int = 0
    private var egCounter: UInt32 = 0

    private var dcBlockL = DCBlocker()
    private var dcBlockR = DCBlocker()

    /// Coarse-detune (DT2) as added octaves. The canonical YM2151 DT2 ratios (×1, ×√2,
    /// ×1.57, ×1.73) expressed as fractions of an octave (MAME's `dt2` index over 768/octave).
    private static let dt2Octaves: [Double] = [0.0, 384.0 / 768.0, 500.0 / 768.0, 608.0 / 768.0]

    /// Fine-detune (DT1) table `[amount 0…3][keycode 0…31]`, in 20-bit phase-increment units —
    /// the same canonical Yamaha `dt_tab` the OPN core uses (ymfm/MAME lineage; BSD-3-Clause,
    /// see THIRD_PARTY). OPM shares the detune behaviour with OPN.
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

    public init(clock: Double = OPM.defaultClock) {
        self.clock = clock
        channels = (0..<8).map { _ in FMChannel() }
        keyCode = Array(repeating: 0, count: 8)
        keyFraction = Array(repeating: 0, count: 8)
        dt1Field = Array(repeating: [0, 0, 0, 0], count: 8)
        dt2Field = Array(repeating: [0, 0, 0, 0], count: 8)
        keyScaleField = Array(repeating: [0, 0, 0, 0], count: 8)
        panLeft = Array(repeating: true, count: 8)
        panRight = Array(repeating: true, count: 8)

        dcBlockL.configure(cutoff: 10, sampleRate: sampleRate)
        dcBlockR.configure(cutoff: 10, sampleRate: sampleRate)
    }

    // MARK: Register write

    /// Write one OPM register. The OPM is single-port; `port` is ignored (present for the
    /// `FMCore` interface). `address` is the 8-bit register, `data` the value.
    public mutating func writeRegister(port: Int, address: UInt8, data: UInt8) {
        // Key on/off carries its own channel + slot mask.
        if address == 0x08 { keyOnOff(data); return }
        // Test / noise / timers / LFO live below 0x20 — decoded but ignored.
        if address < 0x20 { return }

        let ch = Int(address & 0x07)
        if address < 0x40 {
            writeChannelRegister(channel: ch, address: address, data: data)
        } else {
            writeOperatorRegister(channel: ch, op: Int((address >> 3) & 0x03), address: address, data: data)
        }
    }

    private mutating func writeChannelRegister(channel ch: Int, address: UInt8, data: UInt8) {
        switch address & 0x18 {
        case 0x00: // 0x20–0x27: pan (R/L) / feedback / connection (algorithm)
            channels[ch].algorithm = data & 0x07
            channels[ch].feedback = (data >> 3) & 0x07
            panLeft[ch] = (data & 0x40) != 0
            panRight[ch] = (data & 0x80) != 0
        case 0x08: // 0x28–0x2F: key code (octave + note)
            keyCode[ch] = data & 0x7F
            updatePitch(ch)
        case 0x10: // 0x30–0x37: key fraction (top 6 bits of the byte)
            keyFraction[ch] = (data >> 2) & 0x3F
            updatePitch(ch)
        default: // 0x38–0x3F: PMS / AMS — LFO depth, not modeled
            break
        }
    }

    /// OPM register operator order is M1, M2, C1, C2 = logical OP1…OP4 directly, so the
    /// slot bits map straight onto `FMChannel`'s operator indices (no S1/S3/S2/S4 interleave
    /// like OPN). The connection algorithms are shared with OPN, so this gives M1→M2→C1→C2
    /// for algorithm 0, etc.
    private mutating func writeOperatorRegister(channel ch: Int, op: Int, address: UInt8, data: UInt8) {
        switch address & 0xE0 {
        case 0x40: // DT1 / MUL
            channels[ch].multiple[op] = data & 0x0F
            dt1Field[ch][op] = (data >> 4) & 0x07
            updatePitch(ch)
        case 0x60: // TL (7-bit)
            channels[ch].totalLevel[op] = data & 0x7F
        case 0x80: // KS / AR
            keyScaleField[ch][op] = (data >> 6) & 0x03
            channels[ch].envelopes[op].attackRate = data & 0x1F
            updateKeyScale(ch, op)
        case 0xA0: // AMS-EN / D1R (first decay)
            channels[ch].envelopes[op].decayRate = data & 0x1F
        case 0xC0: // DT2 / D2R (second decay / sustain)
            dt2Field[ch][op] = (data >> 6) & 0x03
            channels[ch].envelopes[op].sustainRate = data & 0x1F
            updatePitch(ch)
        default: // 0xE0: D1L (sustain level) / RR
            channels[ch].envelopes[op].sustainLevel = (data >> 4) & 0x0F
            channels[ch].envelopes[op].releaseRate = data & 0x0F
        }
    }

    private mutating func keyOnOff(_ data: UInt8) {
        let ch = Int(data & 0x07)
        // Slot mask is bits 6…3 (M1, M2, C1, C2) → FMChannel's bit-i = OP(i+1).
        channels[ch].setKeyState(slots: data >> 3)
    }

    // MARK: Pitch helpers

    /// Concert-pitch frequency (Hz at the nominal clock) for a channel's note, including the
    /// per-operator coarse detune (DT2). KC = octave (bits 6…4) + note code (bits 3…0, where
    /// the low two bits step within a group of three semitones); KF adds 1/64 semitone steps.
    private func noteFrequency(_ ch: Int, dt2: UInt8) -> Double {
        let kc = keyCode[ch]
        let octave = Int((kc >> 4) & 0x07)
        let note = Int((kc >> 2) & 0x03) * 3 + Int(kc & 0x03) // 0…11 (note index 8 = "A")
        let fraction = Double(keyFraction[ch]) / 64.0
        let semitones = Double(octave - 4) * 12.0 + Double(note - 8) + fraction
        return 440.0 * exp2(semitones / 12.0) * exp2(OPM.dt2Octaves[Int(dt2 & 0x03)])
    }

    private mutating func updatePitch(_ ch: Int) {
        let keycode = Int((keyCode[ch] >> 2) & 0x1F)
        for op in 0..<4 {
            // Build the increment against the nominal rate so the real clock scales pitch.
            let f = noteFrequency(ch, dt2: dt2Field[ch][op])
            let base = Int32((f / OPM.nominalSampleRate * Double(1 << Operator.phaseBits)).rounded())
            // Fine detune (DT1) nudges the increment a few phase units around the base.
            let field = dt1Field[ch][op]
            let detune = Int32(OPM.detuneTable[Int(field & 3) * 32 + keycode])
            let detuned = max((field & 4) != 0 ? base - detune : base + detune, 0)
            // MUL multiplies after detune (MUL 0 means ×0.5).
            let mul = channels[ch].multiple[op]
            let inc = (mul == 0) ? (UInt32(detuned) >> 1) : (UInt32(detuned) &* UInt32(mul))
            channels[ch].operators[op].phaseIncrement = inc & Operator.phaseMask
            updateKeyScale(ch, op)
        }
    }

    private mutating func updateKeyScale(_ ch: Int, _ op: Int) {
        let keycode = (keyCode[ch] >> 2) & 0x1F
        let ks = keyScaleField[ch][op]
        channels[ch].envelopes[op].keyScale = keycode >> (3 - ks)
    }

    // MARK: Clock

    /// Produce one stereo sample (unscaled sums; mixing/clamping happens downstream).
    public mutating func tick() -> (left: Int32, right: Int32) {
        egDivider += 1
        if egDivider >= 3 {
            egDivider = 0
            egCounter &+= 1
            for ch in 0..<8 { channels[ch].clockEnvelopes(egCounter) }
        }

        var left: Int32 = 0
        var right: Int32 = 0
        for ch in 0..<8 {
            let sample = channels[ch].next()
            if panLeft[ch] { left &+= sample }
            if panRight[ch] { right &+= sample }
        }
        if fmVolume != 1.0 {
            left = Int32(Double(left) * fmVolume)
            right = Int32(Double(right) * fmVolume)
        }

        // AC-couple the output like the real chip's DC-blocked analog stage.
        left = Int32(dcBlockL.process(Double(left)))
        right = Int32(dcBlockR.process(Double(right)))
        return (left, right)
    }
}
