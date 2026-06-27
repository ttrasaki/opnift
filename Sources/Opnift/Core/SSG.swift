// Ported from / modeled on ymfm's ssg_engine (Aaron Giles), BSD-3-Clause. The
// volume-to-amplitude table originates from MAME (via ymfm). See THIRD_PARTY.

/// SSG — the AY-3-8910 / YM2149-compatible square-wave side of the OPNA.
///
/// Three tone channels (A/B/C), one noise generator, a mixer and the hardware envelope
/// generator. PC-88/98 FM music leans heavily on the SSG for bass, leads and percussion,
/// so it's essential for a faithful render. Modeled after ymfm's `ssg_engine` (tone
/// toggle, LFSR noise, the `s_amplitudes` table); the envelope (regs 0x0B–0x0D) follows
/// MAME's `ay8910` shape machine. Some files drive volume directly; others set the
/// amplitude "envelope mode" bit and rely on the envelope, which would otherwise be silent.
public struct SSG {

    /// Volume index (0…31) → linear amplitude (ymfm's table, biased so 0 == 0).
    static let amplitudes: [Int32] = [
        0, 32, 78, 141, 178, 222, 262, 306,
        369, 441, 509, 585, 701, 836, 965, 1112,
        1334, 1595, 1853, 2146, 2576, 3081, 3576, 4135,
        5000, 6006, 7023, 8155, 9963, 11976, 14132, 16382,
    ]

    // Registers
    private var tonePeriod: [UInt32] = [0, 0, 0] // 12-bit per channel
    private var noisePeriod: UInt32 = 0          // 5-bit
    private var mixer: UInt8 = 0                  // 0x07: bit c = tone disable, bit 3+c = noise disable
    private var amplitude: [UInt8] = [0, 0, 0]    // 0x08–0x0A: 4-bit level + bit 4 = envelope mode
    private var envPeriod: UInt32 = 0             // 0x0B/0x0C: 16-bit envelope period

    // State
    private var toneCount: [UInt32] = [0, 0, 0]
    private var toneState: [UInt32] = [0, 0, 0]   // square-wave phase (0/1)
    private var noiseCount: UInt32 = 0
    private var noiseState: UInt32 = 1            // 17-bit LFSR

    // Envelope generator (regs 0x0B–0x0D), MAME ay8910 shape machine. `envStep` is a
    // signed down-counter from 31; `envAttack` (0x00 or 0x1F) XORs it to pick the ramp
    // direction; `envVolume` is the 0…31 level fed to `amplitudes` in envelope mode.
    private var envCount: UInt32 = 0
    private var envStep: Int = 0x1F
    private var envAttack: Int = 0
    private var envHold = false
    private var envAlternate = false
    private var envHolding = false
    private var envVolume: Int = 0

    public init() {}

    /// Write an SSG register (addresses 0x00–0x0D).
    public mutating func writeRegister(_ address: UInt8, _ data: UInt8) {
        switch address {
        case 0x00: tonePeriod[0] = (tonePeriod[0] & 0xF00) | UInt32(data)
        case 0x01: tonePeriod[0] = (tonePeriod[0] & 0x0FF) | (UInt32(data & 0x0F) << 8)
        case 0x02: tonePeriod[1] = (tonePeriod[1] & 0xF00) | UInt32(data)
        case 0x03: tonePeriod[1] = (tonePeriod[1] & 0x0FF) | (UInt32(data & 0x0F) << 8)
        case 0x04: tonePeriod[2] = (tonePeriod[2] & 0xF00) | UInt32(data)
        case 0x05: tonePeriod[2] = (tonePeriod[2] & 0x0FF) | (UInt32(data & 0x0F) << 8)
        case 0x06: noisePeriod = UInt32(data & 0x1F)
        case 0x07: mixer = data
        case 0x08: amplitude[0] = data
        case 0x09: amplitude[1] = data
        case 0x0A: amplitude[2] = data
        case 0x0B: envPeriod = (envPeriod & 0xFF00) | UInt32(data)
        case 0x0C: envPeriod = (envPeriod & 0x00FF) | (UInt32(data) << 8)
        case 0x0D: writeEnvelopeShape(data) // 0x0D resets the envelope
        default: break
        }
    }

    /// Reset the envelope to the shape given by reg 0x0D (CONT/ATT/ALT/HOLD in bits 3–0).
    private mutating func writeEnvelopeShape(_ shape: UInt8) {
        envAttack = (shape & 0x04) != 0 ? 0x1F : 0x00
        if (shape & 0x08) == 0 {
            // Continue = 0: one-shot that holds at the end; map to the equivalent
            // hold shape (alternate inverts iff it attacked).
            envHold = true
            envAlternate = envAttack != 0
        } else {
            envHold = (shape & 0x01) != 0
            envAlternate = (shape & 0x02) != 0
        }
        envCount = 0
        envStep = 0x1F
        envHolding = false
        envVolume = envStep ^ envAttack
    }

    /// Advance the envelope one step (called when the period counter elapses).
    private mutating func stepEnvelope() {
        if !envHolding {
            envStep -= 1
            if envStep < 0 {
                if envHold {
                    if envAlternate { envAttack ^= 0x1F }
                    envHolding = true
                    envStep = 0
                } else {
                    if envAlternate { envAttack ^= 0x1F }
                    envStep &= 0x1F
                }
            }
        }
        envVolume = envStep ^ envAttack
    }

    /// Advance one SSG clock (runs at master / 8).
    public mutating func clock() {
        for ch in 0..<3 {
            toneCount[ch] += 1
            if toneCount[ch] >= tonePeriod[ch] {
                toneState[ch] ^= 1
                toneCount[ch] = 0
            }
        }
        noiseCount += 1
        if (noiseCount >> 1) >= noisePeriod && noiseCount != 1 {
            noiseState ^= ((noiseState & 1) ^ ((noiseState >> 3) & 1)) << 17
            noiseState >>= 1
            noiseCount = 0
        }
        // Envelope: one step every `envPeriod` SSG clocks (period 0 behaves as 1), which
        // gives the datasheet step rate of master/(8·EP) since the SSG runs at master/8.
        envCount += 1
        if envCount >= max(envPeriod, 1) {
            envCount = 0
            stepEnvelope()
        }
    }

    /// Current mono output: the sum of the three channels' amplitudes.
    public func output() -> Int32 {
        var sum: Int32 = 0
        let noiseBit = noiseState & 1
        for ch in 0..<3 {
            let toneOn = UInt32((mixer >> ch) & 1) | toneState[ch]
            let noiseOn = UInt32((mixer >> (3 + ch)) & 1) | noiseBit
            if (toneOn & noiseOn) == 0 { continue }
            let index: Int
            if (amplitude[ch] & 0x10) != 0 {
                index = envVolume // envelope mode: the EG's 0…31 level drives the channel
            } else {
                var volume = UInt32(amplitude[ch] & 0x0F) << 1
                if volume != 0 { volume |= 1 } // amplitude 15 → index 31, matching the datasheet
                index = Int(volume)
            }
            sum += SSG.amplitudes[index]
        }
        return sum
    }
}
