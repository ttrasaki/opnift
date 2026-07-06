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
    /// Devices in device-table order, indexed by `command >> 1` in the dump. `nil` marks a
    /// chip family we don't emulate — kept (rather than dropped) so the indices of the
    /// devices we *do* play stay aligned with the command stream. Always non-empty: v1/v2
    /// files (no device table) imply a single OPNA at the standard clock.
    public let devices: [Device?]
    /// The command/dump byte stream (from the dump offset to end of file).
    public let dump: [UInt8]
    /// Loop restart point as an index into `dump`, or nil if the song doesn't loop.
    public let loopIndex: Int?
    /// Metadata from the header's TAG area, keyed by lowercased tag name
    /// (`title`, `artist`, `game`, `year`, `genre`, `comment`, `copyright`,
    /// `s98by`, `system`). v3 files carry a `[S98]` key=value block (UTF-8 with BOM,
    /// Shift-JIS without); v1/v2 files carry only a NUL-terminated title string,
    /// surfaced as `title` — except the conventional `[game] title` form, which is
    /// split into `game` and `title`. Empty if the file has no TAG area.
    public let tags: [String: String]

    /// Convenience accessors for the common TAG fields.
    public var title: String? { tags["title"] }
    public var game: String? { tags["game"] }
    public var artist: String? { tags["artist"] }
    public var copyright: String? { tags["copyright"] }
    public var system: String? { tags["system"] }

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
        let tagOffset = Int(u32(0x10))
        let dumpOffset = Int(u32(0x14))
        let loopOffset = Int(u32(0x18))
        let deviceCount = u32(0x1C)

        tags = S98.parseTags(bytes: bytes, tagOffset: tagOffset)

        guard dumpOffset > 0, dumpOffset <= bytes.count else { throw ParseError.truncated }

        // Resolve the device list: read the v3 device table if present, else assume the
        // common single-OPNA case (v1/v2 carry no table). Each S98 device type maps to the
        // OPN-family chip whose SSG/FM clock domain matches; unsupported families become
        // `nil` (kept in place to preserve command-stream device indices).
        var devices: [Device?] = []
        if deviceCount > 0 {
            for i in 0..<Int(deviceCount) {
                let base = 0x20 + i * 16
                guard base + 8 <= bytes.count else { break }
                let type = u32(base)
                let deviceClock = u32(base + 4)
                if let kind = S98.chipKind(forDeviceType: type) {
                    let clock = deviceClock != 0 ? deviceClock : OPNA.defaultClockHz
                    devices.append(Device(kind: kind, clock: clock))
                } else {
                    devices.append(nil)
                }
            }
        }
        if devices.compactMap({ $0 }).isEmpty {
            devices = [Device(kind: .opna, clock: OPNA.defaultClockHz)]
        }
        self.devices = devices

        tickNumerator = timerInfo == 0 ? 10 : timerInfo
        tickDenominator = timerInfo2 == 0 ? 1000 : timerInfo2

        dump = Array(bytes[dumpOffset...])
        loopIndex = (loopOffset != 0 && loopOffset >= dumpOffset) ? loopOffset - dumpOffset : nil
    }

    /// Parse the header's TAG area (offset field at 0x10). A v3 TAG block starts with the
    /// `[S98]` magic followed by 0x0A-separated `key=value` lines — UTF-8 when a BOM
    /// follows the magic, Shift-JIS otherwise. Anything else (v1/v2) is a NUL-terminated
    /// title string. Returns an empty dictionary when there is no TAG area or it is
    /// unreadable; tag problems never fail the parse.
    static func parseTags(bytes: [UInt8], tagOffset: Int) -> [String: String] {
        guard tagOffset > 0, tagOffset < bytes.count else { return [:] }

        var region = Array(bytes[tagOffset...])
        if let nul = region.firstIndex(of: 0x00) {
            region = Array(region[..<nul])
        }

        let magic: [UInt8] = [0x5B, 0x53, 0x39, 0x38, 0x5D] // "[S98]"
        guard region.count >= magic.count, Array(region[..<magic.count]) == magic else {
            let title = decodeTagText(Array(region))
            return title.isEmpty ? [:] : v1Tags(title: title)
        }
        var body = Array(region[magic.count...])

        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let isUTF8 = body.count >= bom.count && Array(body[..<bom.count]) == bom
        if isUTF8 { body = Array(body[bom.count...]) }

        var tags: [String: String] = [:]
        for line in decodeTagText(body, preferUTF8: isUTF8)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            tags[key] = value
        }
        return tags
    }

    /// Split a v1/v2 title of the form `[game] title` into separate `game` and `title`
    /// tags. The v1 spec defines only a single title string, so rippers conventionally
    /// packed the game name into a leading bracketed prefix. Titles that don't match
    /// (no leading bracket, unclosed/empty bracket, or nothing after it) are kept whole.
    static func v1Tags(title: String) -> [String: String] {
        guard title.hasPrefix("["), let close = title.firstIndex(of: "]") else {
            return ["title": title]
        }
        let game = title[title.index(after: title.startIndex)..<close]
            .trimmingCharacters(in: .whitespaces)
        let rest = title[title.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        guard !game.isEmpty, !rest.isEmpty else { return ["title": title] }
        return ["title": rest, "game": game]
    }

    private static func decodeTagText(_ bytes: [UInt8], preferUTF8: Bool = false) -> String {
        let data = Data(bytes)
        let encodings: [String.Encoding] = preferUTF8 ? [.utf8, .shiftJIS] : [.shiftJIS, .utf8]
        for encoding in encodings {
            if let s = String(data: data, encoding: encoding) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
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
        case 5: return .opm  // YM2151 (OPM)   — master/64 (X68000)
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
        // One voice per device slot, index-aligned with the command stream. Unsupported
        // slots (`nil`) get a silent placeholder so later devices keep their index; no
        // writes are routed to them, so they render silence.
        let voices = song.devices.map { device -> ChipVoice in
            let device = device ?? S98.Device(kind: .opna, clock: OPNA.defaultClockHz)
            return ChipVoice(kind: device.kind, clock: device.clock, sampleRate: Int(sampleRate))
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
            // Drop writes to out-of-range or unsupported (nil) device slots.
            if device < voices.count, device < song.devices.count, song.devices[device] != nil {
                voices[device].writeRegister(port: Int(command) & 1, address: address, data: data)
            }
        }
    }
}
