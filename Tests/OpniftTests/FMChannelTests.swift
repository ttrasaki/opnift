import Testing
@testable import Opnift

@Suite("FM channel")
struct FMChannelTests {

    /// A channel whose envelopes have settled at full volume (attenuation 0).
    /// Default envelope = AR 31, DR 0, SL 0 → attacks to 0 and holds.
    private func settledChannel(algorithm: UInt8, feedback: UInt8 = 0,
                                totalLevel: [UInt8] = [0, 0, 0, 0]) -> FMChannel {
        var ch = FMChannel()
        ch.algorithm = algorithm
        ch.feedback = feedback
        ch.totalLevel = totalLevel
        for i in 0..<4 { ch.operators[i].phaseIncrement = 1 << Operator.waveformShift }
        ch.keyOn()
        for c in 0..<UInt32(256) { ch.clockEnvelopes(c) }
        for env in ch.envelopes { #expect(env.attenuation == 0) }
        return ch
    }

    private func render(_ ch: inout FMChannel, _ count: Int) -> [Int32] {
        (0..<count).map { _ in ch.next() }
    }

    @Test("two identical channels are sample-for-sample deterministic")
    func deterministic() {
        var a = settledChannel(algorithm: 4, feedback: 3)
        var b = settledChannel(algorithm: 4, feedback: 3)
        #expect(render(&a, 2048) == render(&b, 2048))
    }

    @Test("algorithm 7 is additive: equals 4× a single operator")
    func algorithm7Additive() {
        var ch = settledChannel(algorithm: 7)
        var ref = Operator()
        ref.phaseIncrement = 1 << Operator.waveformShift
        for _ in 0..<1024 {
            let expected = Operator.sample(phase: ref.phase, attenuation: 0) &* 4
            #expect(ch.next() == expected)
            ref.advance()
        }
    }

    @Test("muting modulators with TL=127 silences them exactly")
    func mutedOperatorsAreSilent() {
        // Alg 7, only OP1 audible; OP2..OP4 driven to silence.
        var ch = settledChannel(algorithm: 7, totalLevel: [0, 127, 127, 127])
        var ref = Operator()
        ref.phaseIncrement = 1 << Operator.waveformShift
        for _ in 0..<1024 {
            let expected = Operator.sample(phase: ref.phase, attenuation: 0)
            #expect(ch.next() == expected)
            ref.advance()
        }
    }

    @Test("feedback changes OP1's output")
    func feedbackHasEffect() {
        // Alg 7 with only OP1 audible, fb 0 vs fb 7.
        var none = settledChannel(algorithm: 7, feedback: 0, totalLevel: [0, 127, 127, 127])
        var deep = settledChannel(algorithm: 7, feedback: 7, totalLevel: [0, 127, 127, 127])
        #expect(render(&none, 1024) != render(&deep, 1024))
    }

    @Test("modulation adds harmonics: muting the modulators changes the carrier")
    func modulationHasEffect() {
        // Alg 0 chain: full vs modulators muted (carrier OP4 then a pure sine).
        var modulated = settledChannel(algorithm: 0, totalLevel: [0, 0, 0, 0])
        var clean = settledChannel(algorithm: 0, totalLevel: [127, 127, 127, 0])
        #expect(render(&modulated, 1024) != render(&clean, 1024))
    }

    @Test("output is periodic at an integer samples-per-cycle (no feedback)")
    func periodic() {
        // Feedback carries cross-sample state, so exact periodicity needs fb = 0.
        var ch = settledChannel(algorithm: 0, feedback: 0)
        let first = render(&ch, 1024)
        let second = render(&ch, 1024)
        #expect(first == second)
    }
}
