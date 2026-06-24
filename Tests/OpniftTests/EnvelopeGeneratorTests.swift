import Testing
@testable import Opnift

@Suite("Envelope generator")
struct EnvelopeGeneratorTests {

    /// Clock until `state` changes (or `limit` is hit), returning the clock count.
    @discardableResult
    private func run(_ eg: inout EnvelopeGenerator, untilStateChangesFrom from: EnvelopeGenerator.State,
                     limit: Int = 1_000_000) -> Int {
        var n = 0
        while eg.state == from && n < limit {
            eg.clock()
            n += 1
        }
        return n
    }

    @Test("starts off and silent")
    func startsOff() {
        let eg = EnvelopeGenerator()
        #expect(eg.state == .off)
        #expect(eg.attenuation == EnvelopeGenerator.maxAttenuation)
        #expect(!eg.isActive)
    }

    @Test("key-on attacks toward full volume, then decays")
    func attackThenDecay() {
        var eg = EnvelopeGenerator()
        eg.attackRate = 31
        eg.decayRate = 20
        eg.sustainLevel = 4
        eg.keyOn()
        #expect(eg.state == .attack)
        run(&eg, untilStateChangesFrom: .attack)
        #expect(eg.state == .decay)
        #expect(eg.attenuation == 0) // attack peaked at full volume
    }

    @Test("decay falls to the sustain level and holds")
    func decayToSustain() {
        var eg = EnvelopeGenerator()
        eg.attackRate = 31
        eg.decayRate = 24
        eg.sustainRate = 0 // no second decay → holds
        eg.sustainLevel = 6
        eg.keyOn()
        run(&eg, untilStateChangesFrom: .attack) // through attack
        run(&eg, untilStateChangesFrom: .decay)  // through decay
        #expect(eg.state == .sustain)
        let expected = EnvelopeGenerator.sustainTargetLevel(6) >> 8
        #expect(UInt32(eg.attenuation) == expected)
        // With sustainRate 0 it should not move.
        let held = eg.attenuation
        for _ in 0..<1000 { eg.clock() }
        #expect(eg.attenuation == held)
    }

    @Test("attenuation is monotonic non-decreasing through decay")
    func decayMonotonic() {
        var eg = EnvelopeGenerator()
        eg.attackRate = 31
        eg.decayRate = 18
        eg.sustainLevel = 10
        eg.keyOn()
        run(&eg, untilStateChangesFrom: .attack)
        var previous = eg.attenuation
        while eg.state == .decay {
            eg.clock()
            #expect(eg.attenuation >= previous)
            previous = eg.attenuation
        }
    }

    @Test("key-off releases to silence and turns off")
    func release() {
        var eg = EnvelopeGenerator()
        eg.attackRate = 31
        eg.decayRate = 0
        eg.sustainLevel = 0
        eg.releaseRate = 15
        eg.keyOn()
        run(&eg, untilStateChangesFrom: .attack)
        eg.keyOff()
        #expect(eg.state == .release)
        run(&eg, untilStateChangesFrom: .release)
        #expect(eg.state == .off)
        #expect(eg.attenuation == EnvelopeGenerator.maxAttenuation)
    }

    @Test("higher attack rate reaches peak no slower than a lower one")
    func attackRateOrdering() {
        func attackClocks(_ ar: UInt8) -> Int {
            var eg = EnvelopeGenerator()
            eg.attackRate = ar
            eg.keyOn()
            return run(&eg, untilStateChangesFrom: .attack)
        }
        #expect(attackClocks(31) <= attackClocks(20))
        #expect(attackClocks(20) <= attackClocks(10))
    }

    @Test("key-off during attack still releases")
    func keyOffDuringAttack() {
        var eg = EnvelopeGenerator()
        eg.attackRate = 8
        eg.keyOn()
        eg.clock()
        #expect(eg.state == .attack)
        eg.keyOff()
        #expect(eg.state == .release)
    }
}
