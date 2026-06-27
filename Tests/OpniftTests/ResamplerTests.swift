import Foundation
import Testing
@testable import Opnift

@Suite("Streaming resampler")
struct ResamplerTests {

    /// The defining property that fixes the "constant crackle" bug: pulling output in
    /// arbitrary chunk sizes must be bit-identical to one continuous pass. A batch
    /// resampler restarted per block (the old decoder path) fails this.
    @Test("chunked rendering equals a single continuous pass")
    func chunkInvariance() {
        // A ramp-ish native source so interpolation differences would show up.
        var n = 0
        func source() -> (Int32, Int32) {
            n += 1
            let v = Int32((n % 97) * 113 - 5000)   // deterministic, non-trivial
            return (v, -v)
        }

        let outputFrames = 1000

        // Single pass.
        var single = Resampler(inputRate: 55466, outputRate: 44100)
        n = 0
        var onePass = [(Int32, Int32)]()
        for _ in 0..<outputFrames { onePass.append(single.render(source)) }

        // Same total, but pulled in uneven chunks (1, 7, 3, 64, ... sizes).
        var chunked = Resampler(inputRate: 55466, outputRate: 44100)
        n = 0
        var pieces = [(Int32, Int32)]()
        let chunkSizes = [1, 7, 3, 64, 100, 2, 200, 523]   // sums to 900; remainder below
        var produced = 0
        for size in chunkSizes {
            for _ in 0..<size { pieces.append(chunked.render(source)) }
            produced += size
        }
        while produced < outputFrames { pieces.append(chunked.render(source)); produced += 1 }

        #expect(pieces.count == onePass.count)
        for i in 0..<onePass.count {
            #expect(pieces[i].0 == onePass[i].0)
            #expect(pieces[i].1 == onePass[i].1)
        }
    }

    /// A ChipVoice rendered in one block must equal the same voice rendered in chunks —
    /// the end-to-end guarantee the app's decoders now rely on.
    @Test("ChipVoice chunked render equals single-block render")
    func voiceChunkInvariance() {
        func keyAVoice(_ v: ChipVoice) {
            for slot in stride(from: UInt8(0), through: 12, by: 4) {
                v.writeRegister(port: 0, address: 0x30 + slot, data: 0x01)
                v.writeRegister(port: 0, address: 0x40 + slot, data: 0x00)
                v.writeRegister(port: 0, address: 0x50 + slot, data: 0x1F)
                v.writeRegister(port: 0, address: 0x80 + slot, data: 0x0F)
            }
            v.writeRegister(port: 0, address: 0xA4, data: 0x22)
            v.writeRegister(port: 0, address: 0xA0, data: 0x69)
            v.writeRegister(port: 0, address: 0xB0, data: 0x07)  // algorithm 7
            v.writeRegister(port: 0, address: 0xB4, data: 0xC0)  // L+R
            v.writeRegister(port: 0, address: 0x28, data: 0xF0)  // key on all slots
        }

        let frames = 800

        let whole = ChipVoice(type: .ym2608, clock: OPNA.defaultClockHz, sampleRate: 44100)
        keyAVoice(whole)
        var bufWhole = [Int16](repeating: 0, count: frames * 2)
        whole.render(frames: frames, into: &bufWhole, offset: 0)

        let split = ChipVoice(type: .ym2608, clock: OPNA.defaultClockHz, sampleRate: 44100)
        keyAVoice(split)
        var bufSplit = [Int16](repeating: 0, count: frames * 2)
        var off = 0
        for size in [13, 1, 200, 7, 579] {   // sums to 800
            split.render(frames: size, into: &bufSplit, offset: off)
            off += size
        }

        #expect(bufSplit == bufWhole)
    }
}
