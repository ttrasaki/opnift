import Testing
@testable import Opnift

@Suite("Envelope generator")
struct EnvelopeGeneratorTests {

    /// Clock with a monotonically increasing EG counter until `state` changes (or the
    /// limit is hit). Returns the number of EG clocks consumed.
    @discardableResult
    private func run(_ eg: inout EnvelopeGenerator, from: EnvelopeGenerator.State,
                     counter: inout UInt32, limit: Int = 5_000_000) -> Int {
        var n = 0
        while eg.state == from && n < limit {
            eg.clock(counter)
            counter &+= 1
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
        eg.attackRate = 20
        eg.decayRate = 20
        eg.sustainLevel = 4
        eg.keyOn()
        #expect(eg.state == .attack)
        var counter: UInt32 = 0
        run(&eg, from: .attack, counter: &counter)
        #expect(eg.state == .decay)
        #expect(eg.attenuation == 0) // attack peaked at full volume
    }

    @Test("decay falls to the sustain level then holds when D2R is zero")
    func decayToSustain() {
        var eg = EnvelopeGenerator()
        eg.attackRate = 31
        eg.decayRate = 24
        eg.sustainRate = 0 // no second decay
        eg.sustainLevel = 6
        eg.keyOn()
        var counter: UInt32 = 0
        run(&eg, from: .attack, counter: &counter)
        run(&eg, from: .decay, counter: &counter)
        #expect(eg.state == .sustain)
        // Lands at/just past the SL threshold (6 << 5 = 192).
        #expect(eg.attenuation >= 192)
        #expect(eg.attenuation < 192 + 16)
        // D2R 0 advances only via the slowest pattern — effectively held.
        let held = eg.attenuation
        for _ in 0..<2000 { eg.clock(counter); counter &+= 1 }
        #expect(Int(eg.attenuation) - Int(held) <= 1)
    }

    @Test("attenuation is monotonic non-decreasing through decay")
    func decayMonotonic() {
        var eg = EnvelopeGenerator()
        eg.attackRate = 31
        eg.decayRate = 18
        eg.sustainLevel = 10
        eg.keyOn()
        var counter: UInt32 = 0
        run(&eg, from: .attack, counter: &counter)
        var previous = eg.attenuation
        while eg.state == .decay {
            eg.clock(counter)
            counter &+= 1
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
        var counter: UInt32 = 0
        run(&eg, from: .attack, counter: &counter)
        eg.keyOff()
        #expect(eg.state == .release)
        run(&eg, from: .release, counter: &counter)
        #expect(eg.state == .off)
        #expect(eg.attenuation == EnvelopeGenerator.maxAttenuation)
    }

    @Test("higher attack rate reaches peak no slower than a lower one")
    func attackRateOrdering() {
        func attackClocks(_ ar: UInt8) -> Int {
            var eg = EnvelopeGenerator()
            eg.attackRate = ar
            eg.keyOn()
            var counter: UInt32 = 0
            return run(&eg, from: .attack, counter: &counter)
        }
        #expect(attackClocks(28) <= attackClocks(18))
        #expect(attackClocks(18) <= attackClocks(10))
    }

    @Test("key-off during attack still releases")
    func keyOffDuringAttack() {
        var eg = EnvelopeGenerator()
        eg.attackRate = 8
        eg.keyOn()
        eg.clock(0)
        #expect(eg.state == .attack)
        eg.keyOff()
        #expect(eg.state == .release)
    }

    @Test("egRow maps representative rates to the right pattern rows")
    func egRowMapping() {
        #expect(EnvelopeGenerator.egRow(0) == 0)
        #expect(EnvelopeGenerator.egRow(3) == 3)
        #expect(EnvelopeGenerator.egRow(47) == 3)   // still the 0/1 region
        #expect(EnvelopeGenerator.egRow(48) == 4)
        #expect(EnvelopeGenerator.egRow(59) == 15)
        #expect(EnvelopeGenerator.egRow(63) == 16)  // max step
    }
}
