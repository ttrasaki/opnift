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

    /// One emulated chip from the device table, in table order. The S98 command stream
    /// addresses these by index (`command >> 1`), so order matters.
    public struct Device {
        public let kind: ChipKind
        public let clock: UInt32
    }

    public let version: Int
    public let tickNumerator: UInt32
    public let tickDenominator: UInt32
    /// Devices to instantiate, one per `command >> 1` index in the dump. Always non-empty:
    /// v1/v2 files (no device table) imply a single OPNA at the standard clock.
    public let devices: [Device]
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

        // Resolve the device list: read the v3 device table if present, else assume the
        // common single-OPNA case (v1/v2 carry no table). Each S98 device type maps to the
        // OPN-family chip whose SSG/FM clock domain matches; unknown types are skipped.
        var devices: [Device] = []
        if deviceCount > 0 {
            for i in 0..<Int(deviceCount) {
                let base = 0x20 + i * 16
                guard base + 8 <= bytes.count else { break }
                let type = u32(base)
                let deviceClock = u32(base + 4)
                guard let kind = S98.chipKind(forDeviceType: type) else { continue }
                let clock = deviceClock != 0 ? deviceClock : OPNA.defaultClockHz
                devices.append(Device(kind: kind, clock: clock))
            }
        }
        if devices.isEmpty {
            devices = [Device(kind: .opna, clock: OPNA.defaultClockHz)]
        }
        self.devices = devices

        tickNumerator = timerInfo == 0 ? 10 : timerInfo
        tickDenominator = timerInfo2 == 0 ? 1000 : timerInfo2

        dump = Array(bytes[dumpOffset...])
        loopIndex = (loopOffset != 0 && loopOffset >= dumpOffset) ? loopOffset - dumpOffset : nil
    }

    /// Map an S98 v3 device type to the OPN-family `ChipKind` whose clock domain matches,
    /// or nil for types we don't render. The SSG-only PSG (YM2149) is mapped to `.opna`
    /// because that path clocks the SSG at master/8 — the standard YM2149 tone rate
    /// (f = clock/16/TP) — whereas `.opn` would run it an octave high.
    static func chipKind(forDeviceType type: UInt32) -> ChipKind? {
        switch type {
        case 1: return .opna // YM2149 (PSG / SSG-only)
        case 2: return .opn  // YM2203 (OPN)   — master/72
        case 3: return .opna // YM2612 (OPN2)  — master/144
        case 4: return .opna // YM2608 (OPNA)  — master/144
        default: return nil  // 0 = none, or a chip family we don't emulate
        }
    }
}

/// Streaming player that drives the S98 device table's chip(s) from a command stream.
///
/// Most files use one OPNA, but the device table may list several chips (e.g. multiple
/// SSGs); each gets its own `ChipVoice`, addressed by `command >> 1`.
/// S98 timing is in *syncs* of `tickSeconds`; that is converted to output frames and fed
/// to the shared `OPNStreamPlayer` machinery, whose resampler carries phase across blocks.
public final class S98Player: OPNStreamPlayer {

    public let song: S98
    private let outputFramesPerSync: Double

    public init(song: S98, sampleRate: Double = 44100) {
        self.song = song
        let voices = song.devices.map {
            ChipVoice(kind: $0.kind, clock: $0.clock, sampleRate: Int(sampleRate))
        }
        self.outputFramesPerSync = song.tickSeconds * sampleRate
        super.init(voices: voices, outputSampleRate: sampleRate)
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
        default: // device write: command = device index << 1 | port
            guard pos + 1 < dump.count else { pos = dump.count; ended = true; return }
            let address = dump[pos]; let data = dump[pos + 1]; pos += 2
            let device = Int(command) >> 1
            if device < voices.count {
                voices[device].writeRegister(port: Int(command) & 1, address: address, data: data)
            }
        }
    }
}
