import Foundation

/// A parsed S98 log (FM register dump for PC-88/98 chips).
///
/// Supports the common case: a single YM2608 (OPNA) device. v1/v2 files carry no
/// device table (`DeviceCount == 0`) and imply one OPNA at the standard clock; v3
/// device tables are read to pick up the real clock. SSG/ADPCM register writes pass
/// through to the chip (which currently ignores them).
///
/// Timing: one *sync* lasts `TimerInfo / TimerInfo2` seconds (per-field defaults
/// 10 / 1000). For the SORVA set this resolves to 1 ms — verified by total sync count
/// giving a realistic ~66 s song length (10 ms would imply ~11 min).
public struct S98 {

    public enum ParseError: Error { case badMagic, truncated }

    public let version: Int
    public let tickNumerator: UInt32
    public let tickDenominator: UInt32
    public let opnaClock: UInt32
    /// The command/dump byte stream (from the dump offset to end of file).
    public let dump: [UInt8]
    /// Loop restart point as an index into `dump`, or nil if the song doesn't loop.
    public let loopIndex: Int?

    /// Seconds per sync.
    public var tickSeconds: Double { Double(tickNumerator) / Double(tickDenominator) }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x20,
              bytes[0] == 0x53, bytes[1] == 0x39, bytes[2] == 0x38 else { // "S98"
            throw ParseError.badMagic
        }

        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        version = Int(bytes[3]) - 0x30
        let timerInfo = u32(0x04)
        let timerInfo2 = u32(0x08)
        let dumpOffset = Int(u32(0x14))
        let loopOffset = Int(u32(0x18))
        let deviceCount = u32(0x1C)

        guard dumpOffset > 0, dumpOffset <= bytes.count else { throw ParseError.truncated }

        // Resolve the OPNA clock: read the v3 device table if present, else default.
        var clock: UInt32 = OPNA.defaultClockHz
        if deviceCount > 0 {
            for i in 0..<Int(deviceCount) {
                let base = 0x20 + i * 16
                guard base + 8 <= bytes.count else { break }
                let type = u32(base)
                let deviceClock = u32(base + 4)
                // 2 = YM2203 (OPN), 3 = YM2612 (OPN2), 4 = YM2608 (OPNA).
                if type == 2 || type == 3 || type == 4 {
                    if deviceClock != 0 { clock = deviceClock }
                    break
                }
            }
        }
        opnaClock = clock

        tickNumerator = timerInfo == 0 ? 10 : timerInfo
        tickDenominator = timerInfo2 == 0 ? 1000 : timerInfo2

        dump = Array(bytes[dumpOffset...])
        loopIndex = (loopOffset != 0 && loopOffset >= dumpOffset) ? loopOffset - dumpOffset : nil
    }
}

/// Drives an `OPNA` from an `S98` command stream, producing audio.
public struct S98Player {

    public var chip: OPNA
    public let song: S98

    public init(song: S98) {
        self.song = song
        self.chip = OPNA(clock: Double(song.opnaClock))
    }

    /// Render `seconds` of audio at the chip's native rate (unclamped Int32 L/R).
    public mutating func renderNative(seconds: Double) -> (left: [Int32], right: [Int32]) {
        let rate = chip.sampleRate
        let target = Int((seconds * rate).rounded())
        let samplesPerTick = song.tickSeconds * rate

        var left = [Int32]()
        var right = [Int32]()
        left.reserveCapacity(target)
        right.reserveCapacity(target)

        var sampleAccumulator = 0.0
        var pos = 0
        let dump = song.dump

        func renderTicks(_ count: Int) {
            sampleAccumulator += Double(count) * samplesPerTick
            var want = Int(sampleAccumulator)
            sampleAccumulator -= Double(want)
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
            let command = dump[pos]
            pos += 1
            switch command {
            case 0xFF: // one sync
                renderTicks(1)
            case 0xFE: // n+2 syncs, variable-length count
                var n = 0
                var shift = 0
                while pos < dump.count {
                    let byte = dump[pos]
                    pos += 1
                    n |= Int(byte & 0x7F) << shift
                    shift += 7
                    if byte & 0x80 == 0 { break }
                }
                renderTicks(n + 2)
            case 0xFD: // end of dump
                if let loop = song.loopIndex, loop < dump.count {
                    pos = loop
                } else {
                    endedNaturally = true
                    break stream
                }
            default: // device write: even command = port 0, odd = port 1
                guard pos + 1 < dump.count else { pos = dump.count; break }
                let address = dump[pos]
                let data = dump[pos + 1]
                pos += 2
                if Int(command) >> 1 == 0 { // device 0 (the OPNA)
                    chip.writeRegister(port: Int(command) & 1, address: address, data: data)
                }
            }
        }

        // If the song ended before `seconds`, stop near the end — render a short tail so
        // release envelopes ring out, but don't pad the rest with silence. Looping / long
        // songs instead simply hit `target` above.
        if endedNaturally {
            let tail = min(Int(2.0 * rate), target - left.count)
            for _ in 0..<max(0, tail) {
                let (l, r) = chip.tick()
                left.append(l)
                right.append(r)
            }
        } else {
            while left.count < target { // reached the duration cap on a looping/long song
                left.append(0)
                right.append(0)
            }
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
