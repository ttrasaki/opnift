import Foundation
import Testing
@testable import Opnift

@Suite("Mixer & output")
struct OutputTests {

    @Test("clampToInt16 saturates out-of-range sums")
    func clamp() {
        #expect(clampToInt16(0) == 0)
        #expect(clampToInt16(1000) == 1000)
        #expect(clampToInt16(40000) == 32767)
        #expect(clampToInt16(-40000) == -32768)
    }

    @Test("linear resampler changes length by the rate ratio and is a no-op when equal")
    func resampler() {
        let input = [Int32](repeating: 0, count: 1000)
        #expect(resampleLinear(input, inputRate: 44100, outputRate: 44100).count == 1000)
        let down = resampleLinear(input, inputRate: 55466, outputRate: 44100)
        #expect(abs(down.count - Int(1000.0 * 44100.0 / 55466.0)) <= 1)
        // A linear ramp stays monotonic after resampling.
        let ramp = (0..<1000).map { Int32($0) }
        let out = resampleLinear(ramp, inputRate: 48000, outputRate: 44100)
        for i in 1..<out.count { #expect(out[i] >= out[i - 1]) }
    }

    @Test("WAV header is a well-formed 16-bit PCM stereo container")
    func wavHeader() {
        let samples: [Int16] = [0, 0, 100, -100, 200, -200] // 3 stereo frames
        let data = WAV.data(interleaved: samples, channels: 2, sampleRate: 44100)
        #expect(data.count == 44 + samples.count * 2)
        #expect(Array(data[0..<4]) == Array("RIFF".utf8))
        #expect(Array(data[8..<12]) == Array("WAVE".utf8))
        #expect(Array(data[36..<40]) == Array("data".utf8))
        // bits per sample (offset 34) = 16, channels (offset 22) = 2
        #expect(data[34] == 16 && data[35] == 0)
        #expect(data[22] == 2 && data[23] == 0)
        // data chunk size little-endian at offset 40
        let dataSize = UInt32(data[40]) | UInt32(data[41]) << 8 | UInt32(data[42]) << 16 | UInt32(data[43]) << 24
        #expect(dataSize == UInt32(samples.count * 2))
    }

    @Test("render produces interleaved stereo of the expected length")
    func renderLength() {
        var chip = OPNA()
        let pcm = chip.render(seconds: 0.1, sampleRate: 44100)
        let frames = pcm.count / 2
        #expect(pcm.count % 2 == 0)
        #expect(abs(frames - 4410) <= 2)
    }

    @Test("a keyed voice renders audible, in-range PCM that can be written as WAV")
    func renderVoice() throws {
        var chip = OPNA()
        for slotAddr in stride(from: UInt8(0), through: 12, by: 4) {
            chip.writeRegister(port: 0, address: 0x30 + slotAddr, data: 0x01)
            chip.writeRegister(port: 0, address: 0x40 + slotAddr, data: 0x00)
            chip.writeRegister(port: 0, address: 0x50 + slotAddr, data: 0x1F)
            chip.writeRegister(port: 0, address: 0x80 + slotAddr, data: 0x0F)
        }
        chip.writeRegister(port: 0, address: 0xB0, data: 0x07)
        chip.writeRegister(port: 0, address: 0xB4, data: 0xC0)
        chip.writeRegister(port: 0, address: 0xA4, data: (4 << 3) | 0x04)
        chip.writeRegister(port: 0, address: 0xA0, data: 0x10)
        chip.writeRegister(port: 0, address: 0x28, data: 0xF0)

        let pcm = chip.render(seconds: 0.2, sampleRate: 44100)
        let rms = (pcm.map { Double($0) * Double($0) }.reduce(0, +) / Double(pcm.count)).squareRoot()
        #expect(rms > 100)

        // The WAV bytes should be writable and re-readable to the same length.
        let data = WAV.data(interleaved: pcm, channels: 2, sampleRate: 44100)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opnift_test.wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reread = try Data(contentsOf: url)
        #expect(reread.count == data.count)
    }
}
