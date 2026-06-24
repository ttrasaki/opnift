/// A 4-operator FM channel: the core of OPN voicing.
///
/// Four operators (indices 0…3 = OP1…OP4) are wired together by one of 8 **algorithms**
/// and OP1 can modulate itself via **feedback**. Modulation is phase modulation: an
/// operator's signed output is added (in 10-bit waveform-index units) to the phase of
/// the operator(s) it feeds. The operators it doesn't feed are *carriers*, summed to
/// the channel output.
///
/// Total attenuation per operator is `(envelope << 2) + (totalLevel << 5)` so the
/// envelope's 10-bit range and TL's 7-bit range both span ~96 dB to silence in the
/// log domain the sine tables use.
///
/// Parity note: the modulation/feedback shifts here are the canonical *shape* (deep FM,
/// feedback by `>> (10 - fb)`); exact ymfm sample parity is tuned later against golden.
public struct FMChannel {

    /// Connection algorithm, 0…7.
    public var algorithm: UInt8 = 0
    /// OP1 self-feedback depth, 0…7 (0 = none).
    public var feedback: UInt8 = 0
    /// Per-operator total level (TL), 0…127 (0 = loudest).
    public var totalLevel: [UInt8] = [0, 0, 0, 0]
    /// Per-operator frequency multiple (MUL), 0…15 (0 means ×0.5).
    public var multiple: [UInt8] = [1, 1, 1, 1]

    public var operators: [Operator]
    public var envelopes: [EnvelopeGenerator]

    private var feedback0: Int32 = 0 // OP1's previous two outputs, for feedback
    private var feedback1: Int32 = 0
    private var keyLatch: UInt8 = 0  // last per-operator key state (bits 0…3)

    public init() {
        operators = [Operator(), Operator(), Operator(), Operator()]
        envelopes = [EnvelopeGenerator(), EnvelopeGenerator(), EnvelopeGenerator(), EnvelopeGenerator()]
    }

    // MARK: Gate

    public mutating func keyOn() {
        for i in 0..<4 { envelopes[i].keyOn() }
    }

    public mutating func keyOff() {
        for i in 0..<4 { envelopes[i].keyOff() }
    }

    /// Set the per-operator key state from a 4-bit slot mask (bit i = OP(i+1)).
    /// Only edges act: a slot rising keys on (retrigger), falling keys off.
    public mutating func setKeyState(slots: UInt8) {
        let changed = slots ^ keyLatch
        for i in 0..<4 where (changed & (1 << i)) != 0 {
            if (slots & (1 << i)) != 0 {
                envelopes[i].keyOn()
            } else {
                envelopes[i].keyOff()
            }
        }
        keyLatch = slots
    }

    public var isActive: Bool {
        envelopes.contains { $0.isActive }
    }

    // MARK: Frequency

    /// Set the channel pitch; each operator runs at `hz × MUL`.
    public mutating func setFrequency(_ hz: Double, sampleRate: Double) {
        for i in 0..<4 {
            let mul = multiple[i] == 0 ? 0.5 : Double(multiple[i])
            operators[i].setFrequency(hz * mul, sampleRate: sampleRate)
        }
    }

    // MARK: Clocking

    /// Advance all four envelopes by one EG clock.
    public mutating func clockEnvelopes() {
        for i in 0..<4 { envelopes[i].clock() }
    }

    @inline(__always)
    private func attenuation(_ i: Int) -> UInt32 {
        (UInt32(envelopes[i].attenuation) << 2) + (UInt32(totalLevel[i]) << 5)
    }

    @inline(__always)
    private func sample(_ i: Int, modulation: Int32) -> Int32 {
        Operator.sample(phase: operators[i].phase, modulation: modulation, attenuation: attenuation(i))
    }

    /// Produce one output sample. Does not clock envelopes (call `clockEnvelopes`).
    public mutating func next() -> Int32 {
        // OP1, with feedback from its own last two outputs.
        let fbMod: Int32 = feedback == 0 ? 0 : (feedback0 &+ feedback1) >> (10 - Int32(feedback))
        let o0 = sample(0, modulation: fbMod)
        feedback1 = feedback0
        feedback0 = o0

        // OP2…OP4 routed per algorithm (modulation in 10-bit index units, depth = >> 1).
        var o1: Int32 = 0, o2: Int32 = 0, o3: Int32 = 0
        switch algorithm {
        case 0: // OP1→OP2→OP3→OP4
            o1 = sample(1, modulation: o0 >> 1)
            o2 = sample(2, modulation: o1 >> 1)
            o3 = sample(3, modulation: o2 >> 1)
        case 1: // (OP1+OP2)→OP3→OP4
            o1 = sample(1, modulation: 0)
            o2 = sample(2, modulation: (o0 &+ o1) >> 1)
            o3 = sample(3, modulation: o2 >> 1)
        case 2: // OP1→OP4, OP2→OP3→OP4
            o1 = sample(1, modulation: 0)
            o2 = sample(2, modulation: o1 >> 1)
            o3 = sample(3, modulation: (o0 &+ o2) >> 1)
        case 3: // OP1→OP2→OP4, OP3→OP4
            o1 = sample(1, modulation: o0 >> 1)
            o2 = sample(2, modulation: 0)
            o3 = sample(3, modulation: (o1 &+ o2) >> 1)
        case 4: // OP1→OP2, OP3→OP4 (two parallel stacks)
            o1 = sample(1, modulation: o0 >> 1)
            o2 = sample(2, modulation: 0)
            o3 = sample(3, modulation: o2 >> 1)
        case 5: // OP1→OP2, OP1→OP3, OP1→OP4
            o1 = sample(1, modulation: o0 >> 1)
            o2 = sample(2, modulation: o0 >> 1)
            o3 = sample(3, modulation: o0 >> 1)
        case 6: // OP1→OP2, OP3, OP4
            o1 = sample(1, modulation: o0 >> 1)
            o2 = sample(2, modulation: 0)
            o3 = sample(3, modulation: 0)
        default: // 7: all four direct (additive)
            o1 = sample(1, modulation: 0)
            o2 = sample(2, modulation: 0)
            o3 = sample(3, modulation: 0)
        }

        for i in 0..<4 { operators[i].advance() }

        return carrierSum(o0, o1, o2, o3)
    }

    /// Sum of the operators that are carriers for the current algorithm.
    @inline(__always)
    private func carrierSum(_ o0: Int32, _ o1: Int32, _ o2: Int32, _ o3: Int32) -> Int32 {
        switch algorithm {
        case 0, 1, 2, 3: return o3
        case 4: return o1 &+ o3
        case 5, 6: return o1 &+ o2 &+ o3
        default: return o0 &+ o1 &+ o2 &+ o3
        }
    }
}
