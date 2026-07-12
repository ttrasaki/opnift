import Foundation
import Testing
@testable import Opnift

@Suite("LFO (OPN2/OPNA)")
struct LFOTests {

    /// Program channel 0 with a steady, audible patch (algorithm 7, all carriers,
    /// instant attack, no decay) at block 4 / fnum 0x410 (≈ A440).
    private func programVoice(_ chip: inout OPNA, amEnable: Bool = false,
                              amsPmsBits: UInt8 = 0) {
        for slotAddr in stride(from: UInt8(0), through: 12, by: 4) {
            chip.writeRegister(port: 0, address: 0x30 + slotAddr, data: 0x01) // DT0 MUL1
            chip.writeRegister(port: 0, address: 0x40 + slotAddr, data: 0x00) // TL0
            chip.writeRegister(port: 0, address: 0x50 + slotAddr, data: 0x1F) // KS0 AR31
            chip.writeRegister(port: 0, address: 0x60 + slotAddr, data: amEnable ? 0x80 : 0x00)
            chip.writeRegister(port: 0, address: 0x70 + slotAddr, data: 0x00) // SR0
            chip.writeRegister(port: 0, address: 0x80 + slotAddr, data: 0x0F) // SL0 RR15
        }
        chip.writeRegister(port: 0, address: 0xB0, data: 0x07)               // FB0 ALG7
        chip.writeRegister(port: 0, address: 0xB4, data: 0xC0 | amsPmsBits)  // L+R
        chip.writeRegister(port: 0, address: 0xA4, data: (4 << 3) | 0x04)
        chip.writeRegister(port: 0, address: 0xA0, data: 0x10)
        chip.writeRegister(port: 0, address: 0x28, data: 0xF0)               // key on ch0
    }

    /// Tick until `lfoAM` starts a run of zeros (triangle trough), returning the tick
    /// count consumed. The AM triangle descends from 0x3F, so this marks a fixed phase.
    private func ticksToTrough(_ chip: inout OPNA, limit: Int) -> Int? {
        var previous = chip.lfoAM
        for n in 0..<limit {
            _ = chip.tick()
            if chip.lfoAM == 0 && previous != 0 { return n + 1 }
            previous = chip.lfoAM
        }
        return nil
    }

    // MARK: Counter / waveforms

    @Test("LFO disabled parks AM at 0x3F and PM at 0")
    func disabledState() {
        var chip = OPNA(kind: .opn2)
        _ = chip.tick()
        #expect(chip.lfoAM == 0x3F)
        #expect(chip.lfoRawPM == 0)
    }

    @Test("AM triangle spans 0…0x3F and repeats at the rate-programmed period")
    func amTriangleAndPeriod() {
        var chip = OPNA(kind: .opn2)
        chip.writeRegister(port: 0, address: 0x22, data: 0x08 | 0x07) // enable, rate 7

        // Skip the (slightly longer) startup period, then measure trough → trough.
        #expect(ticksToTrough(&chip, limit: 20_000) != nil)
        guard let period = ticksToTrough(&chip, limit: 20_000) else {
            Issue.record("no second LFO trough found"); return
        }
        // Rate 7: 128 steps × (maxCount − 1 = 5) samples ≈ 640 samples ≈ 86.7 Hz
        // (the hardware runs a bit faster than the published 72.2 Hz; ymfm's 0x101
        // reload reproduces that).
        #expect(abs(period - 640) <= 16)

        // Over one period the triangle must reach both extremes, stepwise.
        var seen = Set<UInt32>()
        for _ in 0..<period {
            _ = chip.tick()
            seen.insert(chip.lfoAM)
        }
        #expect(seen.contains(0) && seen.contains(0x3F))
        #expect(seen.allSatisfy { $0 <= 0x3F })
    }

    @Test("slowest rate is ~4 Hz at the native sample rate")
    func slowestRatePeriod() {
        var chip = OPNA(kind: .opn2)
        chip.writeRegister(port: 0, address: 0x22, data: 0x08) // enable, rate 0
        #expect(ticksToTrough(&chip, limit: 40_000) != nil)
        guard let period = ticksToTrough(&chip, limit: 40_000) else {
            Issue.record("no second LFO trough found"); return
        }
        // Rate 0: 128 × (109 − 1) = 13824 samples ≈ 4.0 Hz.
        #expect(abs(period - 13824) <= 128)
    }

    @Test("PM triangle is symmetric over ±7 and sums to zero")
    func pmSymmetry() {
        var chip = OPNA(kind: .opn2)
        chip.writeRegister(port: 0, address: 0x22, data: 0x08 | 0x07)
        _ = ticksToTrough(&chip, limit: 20_000) // align to a period boundary

        var sum = 0, minPM = Int32.max, maxPM = Int32.min
        let samples = 6400 // ~10 periods at rate 7
        for _ in 0..<samples {
            _ = chip.tick()
            sum += Int(chip.lfoRawPM)
            minPM = min(minPM, chip.lfoRawPM)
            maxPM = max(maxPM, chip.lfoRawPM)
        }
        #expect(minPM == -7 && maxPM == 7)
        // Mean cancels over full periods; allow boundary slop of a fraction of a period.
        #expect(abs(Double(sum) / Double(samples)) < 0.2)
    }

    // MARK: AM (tremolo)

    /// Peak |left| per fixed-size window across `count` ticks.
    private func windowPeaks(_ chip: inout OPNA, windows: Int, windowSize: Int) -> [Double] {
        (0..<windows).map { _ in
            var peak: Int32 = 0
            for _ in 0..<windowSize {
                let (l, _) = chip.tick()
                peak = max(peak, abs(l))
            }
            return Double(peak)
        }
    }

    @Test("AMS=3 with AM enabled gives ≈11.8 dB of tremolo")
    func tremoloDepth() {
        var chip = OPNA(kind: .opn2)
        programVoice(&chip, amEnable: true, amsPmsBits: 0x30) // AMS 3, PMS 0
        chip.writeRegister(port: 0, address: 0x22, data: 0x08) // rate 0 (slow → clean)

        _ = windowPeaks(&chip, windows: 4, windowSize: 512) // let attack/DC settle
        let peaks = windowPeaks(&chip, windows: 30, windowSize: 512) // > 1 LFO period
        let depth = 20.0 * log10(peaks.max()! / peaks.min()!)
        #expect(abs(depth - 11.8) < 1.5)
    }

    @Test("AM-disabled operators render identically with the LFO running")
    func amDisableIsTransparent() {
        var lfoOn = OPNA(kind: .opn2)
        var lfoOff = OPNA(kind: .opn2)
        programVoice(&lfoOn, amEnable: false, amsPmsBits: 0x30) // AMS 3, but no op AM
        programVoice(&lfoOff, amEnable: false, amsPmsBits: 0x30)
        lfoOn.writeRegister(port: 0, address: 0x22, data: 0x08 | 0x07)

        for _ in 0..<5000 {
            let a = lfoOn.tick(), b = lfoOff.tick()
            #expect(a == b)
            if a != b { break }
        }
    }

    // MARK: PM (vibrato)

    @Test("PMS=7 swings the phase increment ≈ ±5% around the base pitch")
    func vibratoDepth() {
        var chip = OPNA(kind: .opn2)
        programVoice(&chip, amEnable: false, amsPmsBits: 0x07) // PMS 7
        chip.writeRegister(port: 0, address: 0x22, data: 0x08 | 0x07)

        let base = Double((UInt32(0x410) << 4) >> 1)
        var minInc = UInt32.max, maxInc = UInt32.min
        for _ in 0..<1500 { // > 2 LFO periods at rate 7
            _ = chip.tick()
            let inc = chip.channels[0].operators[0].phaseIncrement
            minInc = min(minInc, inc)
            maxInc = max(maxInc, inc)
        }
        // fnum 0x410, PMS 7, |pm| 7 → fnum12 0x820 ± 97 → ±4.7% (≈ ±80 cents).
        #expect(abs(Double(maxInc) / base - 1.047) < 0.01)
        #expect(abs(Double(minInc) / base - 0.953) < 0.01)
    }

    @Test("PMS=0 renders bit-identically with the LFO running")
    func pmZeroIsTransparent() {
        var lfoOn = OPNA(kind: .opn2)
        var lfoOff = OPNA(kind: .opn2)
        programVoice(&lfoOn)
        programVoice(&lfoOff)
        lfoOn.writeRegister(port: 0, address: 0x22, data: 0x08 | 0x07)

        for _ in 0..<5000 {
            let a = lfoOn.tick(), b = lfoOff.tick()
            #expect(a == b)
            if a != b { break }
        }
    }

    // MARK: Chip gating

    @Test("YM2203 (.opn) ignores LFO registers entirely")
    func opnHasNoLFO() {
        var withWrites = OPNA(kind: .opn)
        var without = OPNA(kind: .opn)
        programVoice(&withWrites, amEnable: true, amsPmsBits: 0x37) // AMS 3 + PMS 7
        programVoice(&without, amEnable: false, amsPmsBits: 0x00)
        withWrites.writeRegister(port: 0, address: 0x22, data: 0x0F)

        for _ in 0..<5000 {
            let a = withWrites.tick(), b = without.tick()
            #expect(a == b)
            if a != b { break }
        }
    }

    @Test("LFO off but AM enabled applies the parked 0x3F attenuation (Venom case)")
    func parkedAMAttenuates() {
        // ymfm: MegaDrive Venom enables per-op AM with the LFO globally off and
        // expects the extra attenuation from the parked counter position.
        var parked = OPNA(kind: .opn2)
        var plain = OPNA(kind: .opn2)
        programVoice(&parked, amEnable: true, amsPmsBits: 0x30) // AMS 3, LFO off
        programVoice(&plain, amEnable: false, amsPmsBits: 0x30)

        func rms(_ chip: inout OPNA) -> Double {
            var acc = 0.0
            for _ in 0..<4000 {
                let (l, _) = chip.tick()
                acc += Double(l) * Double(l)
            }
            return (acc / 4000).squareRoot()
        }
        _ = rms(&parked); _ = rms(&plain) // settle attack
        let depth = 20.0 * log10(rms(&plain) / rms(&parked))
        #expect(abs(depth - 11.8) < 1.0)
    }
}
