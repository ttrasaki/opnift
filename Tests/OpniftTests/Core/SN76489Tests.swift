import Testing
@testable import Opnift

@Suite("SN76489 PSG")
struct SN76489Tests {

    @Test("silent at reset (all attenuators at 15)")
    func silentAtReset() {
        var psg = SN76489()
        for _ in 0..<1000 {
            let (l, r) = psg.tick()
            #expect(l == 0 && r == 0)
        }
    }

    @Test("a tone channel oscillates at the programmed period")
    func toneSquareWave() {
        var psg = SN76489()
        psg.write(0x80) // latch tone ch0, period low nibble = 0
        psg.write(0x01) // data: period high bits = 1 → period 0x010 (16 sub-clocks)
        psg.write(0x90) // latch volume ch0 = 0 (full)

        // Period 16 toggles every 16 master/16 sub-clocks = every 4 ticks, so one full
        // square cycle spans 8 ticks → expect ~2 sign transitions per 8 ticks.
        var transitions = 0
        var previousPositive: Bool? = nil
        for _ in 0..<400 {
            let (l, _) = psg.tick()
            if l != 0 {
                let positive = l > 0
                if let prev = previousPositive, prev != positive { transitions += 1 }
                previousPositive = positive
            }
        }
        #expect(transitions >= 80 && transitions <= 120) // ideal ≈ 100
    }

    @Test("attenuator 15 mutes a programmed tone")
    func attenuatorMutes() {
        var psg = SN76489()
        psg.write(0x80); psg.write(0x01) // tone ch0 period 16
        psg.write(0x90)                  // full volume
        for _ in 0..<100 { _ = psg.tick() }
        psg.write(0x9F)                  // volume ch0 = 15 (mute)
        // After the DC blocker settles, output returns to silence.
        var tail: [Int32] = []
        for _ in 0..<2000 { tail.append(psg.tick().left) }
        let settled = tail.suffix(200)
        #expect(settled.allSatisfy { abs($0) <= 8 })
    }

    @Test("white noise produces an irregular, non-silent signal")
    func whiteNoise() {
        var psg = SN76489()
        psg.write(0xE4) // noise: white, rate 0 (master/512)
        psg.write(0xF0) // noise volume = 0 (full)
        var values = Set<Int32>()
        var nonZero = 0
        for _ in 0..<4000 {
            let (l, _) = psg.tick()
            values.insert(l)
            if l != 0 { nonZero += 1 }
        }
        #expect(nonZero > 1000)     // audibly active
        #expect(values.count > 10)  // irregular — not a clean two-level square
    }
}
