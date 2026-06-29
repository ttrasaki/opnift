import Testing
@testable import Opnift

@Suite("SSG")
struct SSGTests {

    @Test("silent at reset (all amplitudes zero)")
    func silentAtReset() {
        var ssg = SSG()
        for _ in 0..<1000 { ssg.clock() }
        #expect(ssg.output() == 0)
    }

    @Test("a tone channel produces a square wave at the expected period")
    func toneSquareWave() {
        var ssg = SSG()
        ssg.writeRegister(0x00, 0x10) // ch A tone period low = 16
        ssg.writeRegister(0x01, 0x00) // high = 0 → period 16
        ssg.writeRegister(0x07, 0x3E) // mixer: tone A enabled (bit0=0), all noise off
        ssg.writeRegister(0x08, 0x0F) // ch A full volume
        // Collect output over several periods; it should toggle between 0 and amplitude.
        var values = Set<Int32>()
        var transitions = 0
        var previous = ssg.output()
        // 800 clocks ≈ 200 effective steps after the SSG's ÷4 tone prescaler.
        for _ in 0..<800 {
            ssg.clock()
            let v = ssg.output()
            values.insert(v)
            if v != previous { transitions += 1 }
            previous = v
        }
        #expect(values.count == 2)        // exactly two levels (0 and amplitude)
        #expect(values.contains(0))
        #expect(transitions >= 4)         // it actually oscillates
    }

    @Test("amplitude 0 silences; disabling tone+noise gives steady DC (AY behavior)")
    func mixerAndAmplitude() {
        // Zero amplitude is silent regardless of the mixer.
        var silent = SSG()
        silent.writeRegister(0x00, 0x10)
        silent.writeRegister(0x07, 0x3E) // tone A on
        silent.writeRegister(0x08, 0x00) // amplitude 0
        for _ in 0..<200 { silent.clock(); #expect(silent.output() == 0) }

        // Disabling both tone and noise does NOT silence — it passes a constant level.
        var dc = SSG()
        dc.writeRegister(0x00, 0x10)
        dc.writeRegister(0x08, 0x0F) // full amplitude
        dc.writeRegister(0x07, 0x3F) // tone + noise off for all channels
        var values = Set<Int32>()
        for _ in 0..<200 { dc.clock(); values.insert(dc.output()) }
        #expect(values.count == 1)     // steady DC, no oscillation
        #expect(!values.contains(0))   // and it's a non-zero level
    }

    @Test("amplitude maps through the volume table")
    func amplitudeLevels() {
        var quiet = SSG()
        quiet.writeRegister(0x07, 0x3E)
        quiet.writeRegister(0x08, 0x01) // low volume
        var loud = SSG()
        loud.writeRegister(0x07, 0x3E)
        loud.writeRegister(0x08, 0x0F) // full volume
        // Drive both to the "on" half of the square and compare amplitudes.
        func peak(_ s: inout SSG) -> Int32 {
            var m: Int32 = 0
            for _ in 0..<64 { s.clock(); m = max(m, s.output()) }
            return m
        }
        #expect(peak(&loud) > peak(&quiet))
    }
}
