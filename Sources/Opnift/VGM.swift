import Foundation

/// A parsed VGM file (Video Game Music log).
///
/// Supports YM2203 (OPN) and YM2608 (OPNA) chips. Timing is in 44100 Hz samples.
public struct VGM {

    public enum ParseError: Error { case badMagic, truncated, noSupportedChip }

    public let version: UInt32
    public let ym2203Clock: UInt32
    public let ym2608Clock: UInt32
    public let totalSamples: UInt32
    public let dump: [UInt8]
    public let loopIndex: Int?

    public var chipClock: UInt32 {
        ym2203Clock != 0 ? ym2203Clock : ym2608Clock != 0 ? ym2608Clock : OPNA.defaultClockHz
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x40,
              bytes[0] == 0x56, bytes[1] == 0x67,
              bytes[2] == 0x6D, bytes[3] == 0x20
        else { throw ParseError.badMagic }

        func u32(_ offset: Int) -> UInt32 {
            guard offset + 3 < bytes.count else { return 0 }
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        version = u32(0x08)
        totalSamples = u32(0x18)
        ym2203Clock = bytes.count > 0x47 ? u32(0x44) : 0
        ym2608Clock = bytes.count > 0x4B ? u32(0x48) : 0

        guard ym2203Clock != 0 || ym2608Clock != 0 else { throw ParseError.noSupportedChip }

        // Data offset field at 0x34 is relative to 0x34; falls back to 0x40 for old files.
        let dataRelOffset = u32(0x34)
        let dataOffset = (version >= 0x150 && dataRelOffset != 0)
            ? Int(0x34 + dataRelOffset)
            : 0x40

        guard dataOffset <= bytes.count else { throw ParseError.truncated }
        dump = Array(bytes[dataOffset...])

        let loopOff = u32(0x1C)
        if loopOff != 0 {
            let loopAbs = Int(0x1C) + Int(loopOff)
            loopIndex = loopAbs >= dataOffset ? loopAbs - dataOffset : nil
        } else {
            loopIndex = nil
        }
    }
}

/// Drives an `OPNA` from a VGM command stream, producing audio.
public struct VGMPlayer {

    public var chip: OPNA
    public let song: VGM

    public init(song: VGM) {
        self.song = song
        // YM2203 clock present → OPN (master/72); otherwise OPNA (master/144).
        let kind: OPNA.Kind = song.ym2203Clock != 0 ? .opn : .opna
        self.chip = OPNA(clock: Double(song.chipClock), kind: kind)
    }

    /// Render `seconds` of audio at the chip's native rate (unclamped Int32 L/R).
    public mutating func renderNative(seconds: Double) -> (left: [Int32], right: [Int32]) {
        let rate = chip.sampleRate
        let target = Int((seconds * rate).rounded())
        // VGM timing is in 44100 Hz units; convert to native chip samples.
        let nativePerVGM = rate / 44100.0

        var left = [Int32]()
        var right = [Int32]()
        left.reserveCapacity(target)
        right.reserveCapacity(target)

        var accumulator = 0.0
        var pos = 0
        let dump = song.dump

        func waitVGMSamples(_ count: Int) {
            accumulator += Double(count) * nativePerVGM
            var want = Int(accumulator)
            accumulator -= Double(want)
            while want > 0 && left.count < target {
                let (l, r) = chip.tick()
                left.append(l)
                right.append(r)
                want -= 1
            }
        }

        var endedNaturally = false
        stream: while left.count < target {
            guard pos < dump.count else { endedNaturally = true; break }
            let cmd = dump[pos]
            pos += 1
            switch cmd {
            case 0x55:  // YM2203 port 0
                guard pos + 1 < dump.count else { break stream }
                chip.writeRegister(port: 0, address: dump[pos], data: dump[pos + 1])
                pos += 2
            case 0x56:  // YM2608 port 0
                guard pos + 1 < dump.count else { break stream }
                chip.writeRegister(port: 0, address: dump[pos], data: dump[pos + 1])
                pos += 2
            case 0x57:  // YM2608 port 1
                guard pos + 1 < dump.count else { break stream }
                chip.writeRegister(port: 1, address: dump[pos], data: dump[pos + 1])
                pos += 2
            case 0x61:  // wait N samples (16-bit LE)
                guard pos + 1 < dump.count else { break stream }
                let n = Int(dump[pos]) | (Int(dump[pos + 1]) << 8)
                pos += 2
                waitVGMSamples(n)
            case 0x62:  // wait 735 samples (1/60 sec)
                waitVGMSamples(735)
            case 0x63:  // wait 882 samples (1/50 sec)
                waitVGMSamples(882)
            case 0x66:  // end of data
                if let loop = song.loopIndex {
                    pos = loop
                } else {
                    endedNaturally = true
                    break stream
                }
            case 0x70...0x7F:  // wait n+1 samples
                waitVGMSamples(Int(cmd & 0x0F) + 1)
            default:
                break stream  // unknown command — stop safely
            }
        }

        if endedNaturally {
            let tail = min(Int(2.0 * rate), target - left.count)
            for _ in 0..<max(0, tail) {
                let (l, r) = chip.tick()
                left.append(l)
                right.append(r)
            }
        } else {
            while left.count < target { left.append(0); right.append(0) }
        }
        return (left, right)
    }

    /// Render `seconds` of audio, resampled to `sampleRate`, as interleaved 16-bit PCM.
    public mutating func render(seconds: Double, sampleRate: Double = 44100) -> [Int16] {
        let (nativeL, nativeR) = renderNative(seconds: seconds)
        let outL = resampleLinear(nativeL, inputRate: chip.sampleRate, outputRate: sampleRate)
        let outR = resampleLinear(nativeR, inputRate: chip.sampleRate, outputRate: sampleRate)
        let n = min(outL.count, outR.count)
        var interleaved = [Int16]()
        interleaved.reserveCapacity(n * 2)
        for i in 0..<n {
            interleaved.append(clampToInt16(outL[i]))
            interleaved.append(clampToInt16(outR[i]))
        }
        return interleaved
    }
}
