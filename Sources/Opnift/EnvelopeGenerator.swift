// Ported from / modeled on ymfm (Aaron Giles), BSD-3-Clause. The increment table and
// rate logic follow ymfm; `egInc` derives from the canonical Yamaha table (ymfm/MAME).
// See THIRD_PARTY.

/// ADSR envelope generator for one FM operator.
///
/// Works in the **log-attenuation domain** (10-bit, same units the sine tables use):
/// `0` is full volume, `0x3FF` is silence. This uses the canonical Yamaha OPN envelope
/// timing (BSD ymfm / MAME lineage): a global counter gates updates, the per-rate
/// `eg_inc` table supplies 0/1/2/4/8 attenuation steps, and attack is an exponential
/// approach (`level += (~level · inc) >> 4`).
///
/// The generator is clocked by `clock(_:)` with a shared, monotonically increasing EG
/// counter (the chip advances it at fs/3). Update cadence and step size both come from
/// the effective rate, so decay/sustain/release times track real hardware.
public struct EnvelopeGenerator {

    public enum State: Equatable {
        case off       // idle / fully released
        case attack    // rising to peak (attenuation → 0)
        case decay     // falling to the sustain level (D1R)
        case sustain   // holding / slow decay at the sustain level (D2R)
        case release   // falling to silence (RR)
    }

    // MARK: Register parameters (raw Yamaha fields)

    /// Attack rate, 5-bit (0…31).
    public var attackRate: UInt8 = 31
    /// First decay rate (D1R), 5-bit (0…31).
    public var decayRate: UInt8 = 0
    /// Second decay / sustain rate (D2R), 5-bit (0…31).
    public var sustainRate: UInt8 = 0
    /// Release rate (RR), 4-bit (0…15). Effective 5-bit rate is `(RR << 1) | 1`.
    public var releaseRate: UInt8 = 15
    /// Sustain level (SL), 4-bit (0…15). 15 maps to maximum attenuation.
    public var sustainLevel: UInt8 = 0
    /// Rate key-scale contribution from the key code, added to every rate.
    public var keyScale: UInt8 = 0

    // MARK: State

    public static let maxAttenuation: UInt16 = 0x3FF

    /// 10-bit attenuation as a signed value (Int32 so attack's `~level` math works).
    private var level: Int32 = Int32(EnvelopeGenerator.maxAttenuation)
    public private(set) var state: State = .off

    public init() {}

    /// Current 10-bit attenuation (0 = full volume, 0x3FF = silence).
    public var attenuation: UInt16 {
        UInt16(min(max(level, 0), Int32(EnvelopeGenerator.maxAttenuation)))
    }

    public var isActive: Bool { state != .off }

    // MARK: Gate

    public mutating func keyOn() { state = .attack }

    public mutating func keyOff() {
        if state != .off { state = .release }
    }

    // MARK: Clock

    /// Advance the envelope, gated by the shared EG counter.
    public mutating func clock(_ egCounter: UInt32) {
        guard state != .off else { return }

        let rate: Int
        switch state {
        case .attack:  rate = Int(effectiveRate(attackRate))
        case .decay:   rate = Int(effectiveRate(decayRate))
        case .sustain: rate = Int(effectiveRate(sustainRate))
        case .release: rate = Int(releaseEffectiveRate())
        case .off:     return
        }

        // Attack rates 62/63 snap straight to peak.
        if state == .attack && rate >= 62 {
            level = 0
            state = .decay
            return
        }

        let shift = rate < 48 ? (11 - (rate >> 2)) : 0
        guard egCounter & ((1 << shift) - 1) == 0 else { return }
        let phase = Int((egCounter >> shift) & 7)
        let inc = Int32(EnvelopeGenerator.egInc[EnvelopeGenerator.egRow(rate) * 8 + phase])

        switch state {
        case .attack:
            if inc != 0 {
                level += (~level &* inc) >> 4 // exponential approach to 0
                if level <= 0 {
                    level = 0
                    state = .decay
                }
            }
        case .decay:
            level += inc
            if level >= sustainThreshold {
                state = .sustain
            }
            if level > Int32(EnvelopeGenerator.maxAttenuation) {
                level = Int32(EnvelopeGenerator.maxAttenuation)
            }
        case .sustain:
            level = min(level + inc, Int32(EnvelopeGenerator.maxAttenuation))
        case .release:
            level += inc
            if level >= Int32(EnvelopeGenerator.maxAttenuation) {
                level = Int32(EnvelopeGenerator.maxAttenuation)
                state = .off
            }
        case .off:
            break
        }
    }

    // MARK: Rate helpers

    @inline(__always)
    func effectiveRate(_ raw: UInt8) -> UInt8 {
        UInt8(min(63, 2 * Int(raw) + Int(keyScale)))
    }

    @inline(__always)
    func releaseEffectiveRate() -> UInt8 {
        effectiveRate((releaseRate << 1) | 1)
    }

    /// Attenuation (10-bit) at which decay hands off to sustain. SL 15 → silence.
    private var sustainThreshold: Int32 {
        sustainLevel >= 15 ? Int32(EnvelopeGenerator.maxAttenuation) : Int32(sustainLevel) << 5
    }

    // MARK: Canonical OPN envelope increment table (BSD ymfm / MAME lineage)

    /// `eg_inc[19 × 8]`: per-rate-group, per-phase attenuation step (0/1/2/4/8).
    static let egInc: [UInt8] = [
        0, 1, 0, 1, 0, 1, 0, 1, // 0: rates < 48, low bits 0
        0, 1, 0, 1, 1, 1, 0, 1, // 1: rates < 48, low bits 1
        0, 1, 1, 1, 0, 1, 1, 1, // 2: rates < 48, low bits 2
        0, 1, 1, 1, 1, 1, 1, 1, // 3: rates < 48, low bits 3
        1, 1, 1, 1, 1, 1, 1, 1, // 4: rate 48
        1, 1, 1, 2, 1, 1, 1, 2, // 5: rate 49
        1, 2, 1, 2, 1, 2, 1, 2, // 6: rate 50
        1, 2, 2, 2, 1, 2, 2, 2, // 7: rate 51
        2, 2, 2, 2, 2, 2, 2, 2, // 8: rate 52
        2, 2, 2, 4, 2, 2, 2, 4, // 9: rate 53
        2, 4, 2, 4, 2, 4, 2, 4, // 10: rate 54
        2, 4, 4, 4, 2, 4, 4, 4, // 11: rate 55
        4, 4, 4, 4, 4, 4, 4, 4, // 12: rate 56
        4, 4, 4, 8, 4, 4, 4, 8, // 13: rate 57
        4, 8, 4, 8, 4, 8, 4, 8, // 14: rate 58
        4, 8, 8, 8, 4, 8, 8, 8, // 15: rate 59
        8, 8, 8, 8, 8, 8, 8, 8, // 16: rates 60–63 (max step)
        8, 8, 8, 8, 8, 8, 8, 8, // 17: (mirror of 16)
        0, 0, 0, 0, 0, 0, 0, 0, // 18: never (unused here)
    ]

    /// Map an effective rate (0…63) to its `eg_inc` row.
    @inline(__always)
    static func egRow(_ rate: Int) -> Int {
        if rate < 48 { return rate & 3 }     // rows 0–3 (0/1 pattern, slowed by shift)
        let high = rate >> 2
        if high >= 15 { return 16 }          // rates 60–63 → max step
        return 4 + (high - 12) * 4 + (rate & 3)
    }
}
