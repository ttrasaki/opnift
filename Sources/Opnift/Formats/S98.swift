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
    /// Chip family implied by the device table (OPN = YM2203, OPNA = YM2608 / OPN2).
    public let chipKind: ChipKind
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

        // Resolve the chip clock & kind: read the v3 device table if present, else default.
        var clock: UInt32 = OPNA.defaultClockHz
        var kind: ChipKind = .opna
        if deviceCount > 0 {
            for i in 0..<Int(deviceCount) {
                let base = 0x20 + i * 16
                guard base + 8 <= bytes.count else { break }
                let type = u32(base)
                let deviceClock = u32(base + 4)
                // 2 = YM2203 (OPN), 3 = YM2612 (OPN2), 4 = YM2608 (OPNA).
                if type == 2 || type == 3 || type == 4 {
                    if deviceClock != 0 { clock = deviceClock }
                    // OPN (YM2203) = master/72; OPN2/OPNA = master/144.
                    kind = (type == 2) ? .opn : .opna
                    break
                }
            }
        }
        opnaClock = clock
        chipKind = kind

        tickNumerator = timerInfo == 0 ? 10 : timerInfo
        tickDenominator = timerInfo2 == 0 ? 1000 : timerInfo2

        dump = Array(bytes[dumpOffset...])
        loopIndex = (loopOffset != 0 && loopOffset >= dumpOffset) ? loopOffset - dumpOffset : nil
    }
}

/// Streaming player that drives a single OPN/OPNA chip from an `S98` command stream.
///
/// S98 timing is in *syncs* of `tickSeconds`; that is converted to output frames and fed
/// to the shared `OPNStreamPlayer` machinery, whose resampler carries phase across blocks.
public final class S98Player: OPNStreamPlayer {

    public let song: S98
    private let chip: ChipVoice
    private let outputFramesPerSync: Double

    public init(song: S98, sampleRate: Double = 44100) {
        self.song = song
        let voice = ChipVoice(kind: song.chipKind, clock: song.opnaClock, sampleRate: Int(sampleRate))
        self.chip = voice
        self.outputFramesPerSync = song.tickSeconds * sampleRate
        super.init(voices: [voice], outputSampleRate: sampleRate)
        pos = 0
    }

    override func rewindToStart() { pos = 0 }

    override func processEvent() {
        let dump = song.dump
        guard pos < dump.count else { loopOrEnd(loopPos: song.loopIndex); return }
        let command = dump[pos]; pos += 1

        switch command {
        case 0xFF: // one sync
            emitWait(outputFrames: outputFramesPerSync)
        case 0xFE: // n+2 syncs, variable-length count
            var n = 0
            var shift = 0
            while pos < dump.count {
                let byte = dump[pos]; pos += 1
                n |= Int(byte & 0x7F) << shift
                shift += 7
                if byte & 0x80 == 0 { break }
            }
            emitWait(outputFrames: Double(n + 2) * outputFramesPerSync)
        case 0xFD: // end of dump
            loopOrEnd(loopPos: (song.loopIndex.flatMap { $0 < dump.count ? $0 : nil }))
        default: // device write: even command = port 0, odd = port 1
            guard pos + 1 < dump.count else { pos = dump.count; ended = true; return }
            let address = dump[pos]; let data = dump[pos + 1]; pos += 2
            if Int(command) >> 1 == 0 { // device 0 (the OPNA)
                chip.writeRegister(port: Int(command) & 1, address: address, data: data)
            }
        }
    }
}
