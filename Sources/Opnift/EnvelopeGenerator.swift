/// ADSR envelope generator for one FM operator.
///
/// Works in the **log-attenuation domain** (same units as the sine tables): `0` is
/// full volume, `maxAttenuation` (0x3FF) is silence. Attack approaches `0`
/// exponentially; decay, sustain and release add linearly toward silence — which is
/// the perceptual shape of the Yamaha EG.
///
/// Note on parity: the real OPN advances the envelope with a discrete 0/1/2/4/8
/// increment table clocked by a global counter. Here the *shape and state machine*
/// are faithful, but the per-clock increment policy is a smooth approximation. Exact
/// sample parity vs ymfm is deferred to chip integration, where it can be diffed
/// against golden; the state machine and API stay the same when that swap happens.
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
    /// Rate key-scale contribution from the key code (0…3), added to every rate.
    public var keyScale: UInt8 = 0

    // MARK: State

    public static let maxAttenuation: UInt16 = 0x3FF

    private static let scaleBits: UInt32 = 8
    private static let maxLevel: UInt32 = UInt32(maxAttenuation) << scaleBits

    /// Internal high-resolution level (10-bit attenuation << scaleBits). 0 = loud.
    private var level: UInt32 = EnvelopeGenerator.maxLevel
    public private(set) var state: State = .off

    public init() {}

    /// Current 10-bit attenuation (0 = full volume, 0x3FF = silence).
    public var attenuation: UInt16 {
        UInt16(min(level >> EnvelopeGenerator.scaleBits, UInt32(EnvelopeGenerator.maxAttenuation)))
    }

    /// Whether the operator is currently producing (or releasing) sound.
    public var isActive: Bool { state != .off }

    // MARK: Gate

    /// Key-on: (re)start the attack from the current level.
    public mutating func keyOn() {
        state = .attack
    }

    /// Key-off: enter the release phase if currently sounding.
    public mutating func keyOff() {
        if state != .off {
            state = .release
        }
    }

    // MARK: Clock

    /// Advance the envelope by one EG clock.
    public mutating func clock() {
        switch state {
        case .off:
            return

        case .attack:
            let inc = EnvelopeGenerator.linearIncrement(forRate: effectiveRate(attackRate))
            // Exponential approach: step shrinks as we near 0, but never stalls.
            let proportional = (level >> 5) &* inc >> 6
            let step = max(proportional, inc)
            if step >= level {
                level = 0
                state = .decay
            } else {
                level -= step
            }

        case .decay:
            let target = EnvelopeGenerator.sustainTargetLevel(sustainLevel)
            level = min(level &+ EnvelopeGenerator.linearIncrement(forRate: effectiveRate(decayRate)), target)
            if level >= target {
                state = .sustain
            }

        case .sustain:
            level = min(level &+ EnvelopeGenerator.linearIncrement(forRate: effectiveRate(sustainRate)),
                        EnvelopeGenerator.maxLevel)

        case .release:
            level = min(level &+ EnvelopeGenerator.linearIncrement(forRate: releaseEffectiveRate()),
                        EnvelopeGenerator.maxLevel)
            if level >= EnvelopeGenerator.maxLevel {
                state = .off
            }
        }
    }

    // MARK: Rate helpers

    /// Effective rate for a 5-bit register field: `min(63, 2·rate + keyScale)`.
    @inline(__always)
    func effectiveRate(_ raw: UInt8) -> UInt8 {
        UInt8(min(63, 2 * Int(raw) + Int(keyScale)))
    }

    /// Effective release rate: RR is 4-bit, expanded to a 5-bit `(RR<<1)|1` first.
    @inline(__always)
    func releaseEffectiveRate() -> UInt8 {
        effectiveRate((releaseRate << 1) | 1)
    }

    /// Per-clock attenuation increment (in 1/256 units) for an effective rate 0…63.
    /// Doubles every 4 rate steps; the low two bits interpolate between doublings.
    @inline(__always)
    static func linearIncrement(forRate rate: UInt8) -> UInt32 {
        let r = min(rate, 63)
        if r < 4 { return 0 } // rates 0–3 effectively never advance
        let base = UInt32(1) << (r >> 2)
        let frac = base &* UInt32(r & 3) / 4
        return base &+ frac
    }

    /// Target level (high-res) where decay hands off to sustain. SL 15 → silence.
    @inline(__always)
    static func sustainTargetLevel(_ sustainLevel: UInt8) -> UInt32 {
        let atten = (sustainLevel >= 15) ? UInt32(maxAttenuation) : UInt32(sustainLevel) << 5
        return atten << scaleBits
    }
}
