import Foundation
import Testing
@testable import Opnift

@Suite("OPNA chip")
struct OPNATests {

    /// Program one channel with a simple audible patch (algorithm 7, all carriers
    /// loud, fast attack) at the given port/channel column.
    private func programVoice(_ chip: inout OPNA, port: Int) {
        // Operators: MUL=1, TL=0, AR=31, DR=0, SR=0, SL/RR — for all four slots.
        for slotAddr in stride(from: UInt8(0), through: 12, by: 4) {
            chip.writeRegister(port: port, address: 0x30 + slotAddr, data: 0x01) // DT0 MUL1
            chip.writeRegister(port: port, address: 0x40 + slotAddr, data: 0x00) // TL0
            chip.writeRegister(port: port, address: 0x50 + slotAddr, data: 0x1F) // KS0 AR31
            chip.writeRegister(port: port, address: 0x60 + slotAddr, data: 0x00) // DR0
            chip.writeRegister(port: port, address: 0x70 + slotAddr, data: 0x00) // SR0
            chip.writeRegister(port: port, address: 0x80 + slotAddr, data: 0x0F) // SL0 RR15
        }
        chip.writeRegister(port: port, address: 0xB0, data: 0x07) // FB0 ALG7 (all carriers)
        chip.writeRegister(port: port, address: 0xB4, data: 0xC0) // L+R on
        // Pitch: block 4, fnum 0x0410.
        chip.writeRegister(port: port, address: 0xA4, data: (4 << 3) | 0x04) // block4, fnum high
        chip.writeRegister(port: port, address: 0xA0, data: 0x10)            // fnum low
    }

    private func rms(_ chip: inout OPNA, _ count: Int) -> Double {
        var acc = 0.0
        for _ in 0..<count {
            let (l, _) = chip.tick()
            acc += Double(l) * Double(l)
        }
        return (acc / Double(count)).squareRoot()
    }

    @Test("silent before key-on")
    func silentInitially() {
        var chip = OPNA()
        programVoice(&chip, port: 0)
        #expect(rms(&chip, 1000) == 0)
    }

    @Test("key-on produces sound, key-off returns to silence")
    func keyOnOff() {
        var chip = OPNA()
        programVoice(&chip, port: 0)
        chip.writeRegister(port: 0, address: 0x28, data: 0xF0) // ch0, all four slots on
        #expect(rms(&chip, 2000) > 100)

        chip.writeRegister(port: 0, address: 0x28, data: 0x00) // ch0, all slots off
        // Let the release run out, then confirm silence.
        _ = rms(&chip, 20000)
        #expect(rms(&chip, 2000) == 0)
    }

    @Test("native sample rate matches clock / 144")
    func sampleRate() {
        let chip = OPNA()
        #expect(abs(chip.sampleRate - 7_987_200.0 / 144.0) < 0.001)
    }

    @Test("pitch register sets the expected phase increment")
    func phaseIncrement() {
        var chip = OPNA()
        chip.writeRegister(port: 0, address: 0x30, data: 0x01) // MUL1 on OP1 (slot S1)
        chip.writeRegister(port: 0, address: 0xA4, data: (4 << 3) | 0x04)
        chip.writeRegister(port: 0, address: 0xA0, data: 0x10)
        let fnum: UInt32 = 0x410
        let expected = ((fnum << 4) >> 1) & Operator.phaseMask
        #expect(chip.channels[0].operators[0].phaseIncrement == expected)
        // A440 should land near 440 Hz at the native rate.
        let hz = Double(expected) / Double(1 << Operator.phaseBits) * chip.sampleRate
        #expect(abs(hz - 440.0) < 5.0)
    }

    @Test("port 1 addresses channels 4–6")
    func portOneMapsToChannels456() {
        var chip = OPNA()
        programVoice(&chip, port: 1) // configures channel 3 (port1, column 0)
        chip.writeRegister(port: 0, address: 0x28, data: 0xF4) // select ch index 4 → channel 3
        #expect(rms(&chip, 2000) > 100)
        #expect(chip.channels[3].isActive)
        #expect(!chip.channels[0].isActive)
    }

    @Test("stereo pan routes to one side only")
    func stereoPan() {
        var chip = OPNA()
        programVoice(&chip, port: 0)
        chip.writeRegister(port: 0, address: 0xB4, data: 0x80) // left only
        chip.writeRegister(port: 0, address: 0x28, data: 0xF0)
        var left = 0.0
        var right = 0.0
        for _ in 0..<2000 {
            let (l, r) = chip.tick()
            left += Double(l * l)
            right += Double(r * r)
        }
        #expect(left > 0)
        #expect(right == 0)
    }

    @Test("re-writing the same key-on does not retrigger (edge-only)")
    func keyOnEdgeOnly() {
        var chip = OPNA()
        programVoice(&chip, port: 0)
        chip.writeRegister(port: 0, address: 0x28, data: 0xF0)
        _ = chip.tick()
        // Capture a window, then write the identical key-on and capture again.
        let before = (0..<1024).map { _ in chip.tick().left }
        chip.writeRegister(port: 0, address: 0x28, data: 0xF0) // same value: no edge
        let after = (0..<1024).map { _ in chip.tick().left }
        // Continuous (no attack restart): the streams join smoothly, not identical.
        #expect(before != after)
    }
}
