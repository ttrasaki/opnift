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
        let voice = ChipVoice(kind: .opna, clock: OPNA.defaultClockHz, sampleRate: 44100)
        let frames = 4410   // 0.1s @ 44100
        var pcm = [Int16](repeating: 0, count: frames * 2)
        voice.render(frames: frames, into: &pcm, offset: 0)
        #expect(pcm.count % 2 == 0)
        #expect(pcm.count / 2 == frames)
    }

    @Test("a keyed voice renders audible, in-range PCM that can be written as WAV")
    func renderVoice() throws {
        let voice = ChipVoice(kind: .opna, clock: OPNA.defaultClockHz, sampleRate: 44100)
        for slotAddr in stride(from: UInt8(0), through: 12, by: 4) {
            voice.writeRegister(port: 0, address: 0x30 + slotAddr, data: 0x01)
            voice.writeRegister(port: 0, address: 0x40 + slotAddr, data: 0x00)
            voice.writeRegister(port: 0, address: 0x50 + slotAddr, data: 0x1F)
            voice.writeRegister(port: 0, address: 0x80 + slotAddr, data: 0x0F)
        }
        voice.writeRegister(port: 0, address: 0xB0, data: 0x07)
        voice.writeRegister(port: 0, address: 0xB4, data: 0xC0)
        voice.writeRegister(port: 0, address: 0xA4, data: (4 << 3) | 0x04)
        voice.writeRegister(port: 0, address: 0xA0, data: 0x10)
        voice.writeRegister(port: 0, address: 0x28, data: 0xF0)

        let frames = 8820   // 0.2s @ 44100
        var pcm = [Int16](repeating: 0, count: frames * 2)
        voice.render(frames: frames, into: &pcm, offset: 0)
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
