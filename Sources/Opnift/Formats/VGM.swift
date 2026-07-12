import Foundation

/// A parsed VGM file (Video Game Music log).
///
/// Supports YM2203 (OPN), YM2608 (OPNA), YM2612 (OPN2) and YM2151 (OPM) chips. Timing is
/// in 44100 Hz samples. The YM2151 path is what plays X68000 VGMs (FM via OPM cmd 0x54);
/// the YM2612 path plays Mega Drive VGMs (FM + ch6 DAC — the console's SN76489 PSG is
/// not yet modeled).
public struct VGM {

    public enum ParseError: Error { case badMagic, truncated, noSupportedChip }

    public let version: UInt32
    public let ym2203Clock: UInt32
    public let ym2608Clock: UInt32
    public let ym2612Clock: UInt32
    public let ym2151Clock: UInt32
    public let totalSamples: UInt32
    public let dump: [UInt8]
    public let loopIndex: Int?

    public var chipClock: UInt32 {
        ym2203Clock != 0 ? ym2203Clock
            : ym2608Clock != 0 ? ym2608Clock
            : ym2612Clock != 0 ? ym2612Clock
            : ym2151Clock != 0 ? ym2151Clock
            : OPNA.defaultClockHz
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

        // Data offset field at 0x34 is relative to 0x34; falls back to 0x40 for old files.
        let dataRelOffset = u32(0x34)
        let dataOffset = (version >= 0x150 && dataRelOffset != 0)
            ? Int(0x34 + dataRelOffset)
            : 0x40

        guard dataOffset <= bytes.count else { throw ParseError.truncated }

        // The YM2203 (0x44) and YM2608 (0x48) clock fields were added in VGM v1.51.
        // In older files those offsets are undefined header bytes — and since old data
        // starts at 0x40, they can be live command-stream data. Only trust them when the
        // version declares them and the field lies entirely within the header (before the
        // data stream). The upper two bits are dual-chip / clock-divider flags, not clock.
        let clockMask: UInt32 = 0x3FFF_FFFF
        let hasV151Clocks = version >= 0x151
        ym2203Clock = (hasV151Clocks && 0x44 + 4 <= dataOffset) ? u32(0x44) & clockMask : 0
        ym2608Clock = (hasV151Clocks && 0x48 + 4 <= dataOffset) ? u32(0x48) & clockMask : 0
        // The YM2612 (0x2C) and YM2151 (0x30) clock fields date to VGM v1.10 (well before
        // the OPN fields), so they're trustworthy on far more files; only require them to
        // lie within the header.
        let hasV110Clocks = version >= 0x110
        ym2612Clock = (hasV110Clocks && 0x2C + 4 <= dataOffset) ? u32(0x2C) & clockMask : 0
        ym2151Clock = (hasV110Clocks && 0x30 + 4 <= dataOffset) ? u32(0x30) & clockMask : 0

        guard ym2203Clock != 0 || ym2608Clock != 0 || ym2612Clock != 0 || ym2151Clock != 0 else {
            throw ParseError.noSupportedChip
        }
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

/// Streaming player that drives one or two OPN/OPNA chips from a VGM command stream.
///
/// VGM timing is in 44100 Hz units; that is converted to output frames and fed to the
/// shared `OPNStreamPlayer` machinery, which carries each chip's resampler phase across
/// blocks (no per-block seam artifacts).
public final class VGMPlayer: OPNStreamPlayer {

    public let song: VGM
    private let ym2203: ChipVoice?   // VGM cmd 0x55
    private let ym2608: ChipVoice?   // VGM cmd 0x56 (port 0) / 0x57 (port 1)
    private let ym2612: ChipVoice?   // VGM cmd 0x52 (port 0) / 0x53 (port 1)
    private let ym2151: ChipVoice?   // VGM cmd 0x54 (OPM, single port)
    private let outputFramesPerVGMSample: Double

    // YM2612 PCM data bank (VGM data blocks type 0x00) and its read cursor. Cmd
    // 0x80–0x8F streams one byte per command to the DAC (reg 0x2A); cmd 0xE0 seeks.
    private var dataBank: [UInt8] = []
    private var dataBankPos = 0

    public init(song: VGM, sampleRate: Double = 44100) {
        self.song = song
        let v3 = song.ym2203Clock != 0
            ? ChipVoice(kind: .opn, clock: song.ym2203Clock, sampleRate: Int(sampleRate)) : nil
        let v8 = song.ym2608Clock != 0
            ? ChipVoice(kind: .opna, clock: song.ym2608Clock, sampleRate: Int(sampleRate)) : nil
        let v12 = song.ym2612Clock != 0
            ? ChipVoice(kind: .opn2, clock: song.ym2612Clock, sampleRate: Int(sampleRate)) : nil
        let vM = song.ym2151Clock != 0
            ? ChipVoice(kind: .opm, clock: song.ym2151Clock, sampleRate: Int(sampleRate)) : nil
        self.ym2203 = v3
        self.ym2608 = v8
        self.ym2612 = v12
        self.ym2151 = vM
        self.outputFramesPerVGMSample = sampleRate / 44100.0
        super.init(voices: [v3, v8, v12, vM].compactMap { $0 }, outputSampleRate: sampleRate)
        pos = 0
    }

    override func rewindToStart() {
        pos = 0
        // Replaying from the top re-reads the 0x67 data blocks; drop the bank so they
        // don't append twice.
        dataBank.removeAll()
        dataBankPos = 0
    }

    /// Operand byte count for VGM commands we don't act on, so `pos` advances correctly.
    private func operandCount(_ cmd: UInt8) -> Int {
        switch cmd {
        case 0x30...0x3F:        return 1
        case 0x40...0x4E:        return 2
        case 0x4F, 0x50:         return 1
        case 0x51...0x5F:        return 2
        case 0x68:               return 11   // PCM RAM write
        case 0x90, 0x91, 0x95:   return 4    // DAC stream control
        case 0x92:               return 5
        case 0x93:               return 10
        case 0x94:               return 1
        case 0xA0...0xBF:        return 2
        case 0xC0...0xDF:        return 3
        case 0xE0...0xE1:        return 4
        default:                 return 0
        }
    }

    override func processEvent() {
        let dump = song.dump
        guard pos < dump.count else { loopOrEnd(loopPos: song.loopIndex); return }
        let cmd = dump[pos]; pos += 1

        switch cmd {
        case 0x52:  // YM2612 port 0
            guard pos + 1 < dump.count else { ended = true; return }
            ym2612?.writeRegister(port: 0, address: dump[pos], data: dump[pos + 1]); pos += 2
        case 0x53:  // YM2612 port 1
            guard pos + 1 < dump.count else { ended = true; return }
            ym2612?.writeRegister(port: 1, address: dump[pos], data: dump[pos + 1]); pos += 2
        case 0x54:  // YM2151 (OPM, single port)
            guard pos + 1 < dump.count else { ended = true; return }
            ym2151?.writeRegister(port: 0, address: dump[pos], data: dump[pos + 1]); pos += 2
        case 0x55:  // YM2203 port 0
            guard pos + 1 < dump.count else { ended = true; return }
            ym2203?.writeRegister(port: 0, address: dump[pos], data: dump[pos + 1]); pos += 2
        case 0x56:  // YM2608 port 0
            guard pos + 1 < dump.count else { ended = true; return }
            ym2608?.writeRegister(port: 0, address: dump[pos], data: dump[pos + 1]); pos += 2
        case 0x57:  // YM2608 port 1
            guard pos + 1 < dump.count else { ended = true; return }
            ym2608?.writeRegister(port: 1, address: dump[pos], data: dump[pos + 1]); pos += 2
        case 0x61:  // wait N samples (16-bit LE)
            guard pos + 1 < dump.count else { ended = true; return }
            let n = Int(dump[pos]) | (Int(dump[pos + 1]) << 8); pos += 2
            emitWait(outputFrames: Double(n) * outputFramesPerVGMSample)
        case 0x62:  emitWait(outputFrames: 735 * outputFramesPerVGMSample)  // 1/60 s
        case 0x63:  emitWait(outputFrames: 882 * outputFramesPerVGMSample)  // 1/50 s
        case 0x66:  loopOrEnd(loopPos: song.loopIndex)
        case 0x70...0x7F:  // wait n+1 samples
            emitWait(outputFrames: Double(Int(cmd & 0x0F) + 1) * outputFramesPerVGMSample)
        case 0x80...0x8F:  // YM2612 DAC: write next bank byte to reg 0x2A, then wait n
            if dataBankPos < dataBank.count {
                ym2612?.writeRegister(port: 0, address: 0x2A, data: dataBank[dataBankPos])
                dataBankPos += 1
            }
            emitWait(outputFrames: Double(Int(cmd & 0x0F)) * outputFramesPerVGMSample)
        case 0xE0:  // seek the DAC data-bank cursor (u32 LE)
            guard pos + 3 < dump.count else { ended = true; return }
            dataBankPos = Int(dump[pos]) | Int(dump[pos + 1]) << 8
                        | Int(dump[pos + 2]) << 16 | Int(dump[pos + 3]) << 24
            pos += 4
        case 0x67:  // data block: 0x66, type, u32 size, data...
            guard pos + 6 <= dump.count else { ended = true; return }
            let size = Int(dump[pos + 2]) | Int(dump[pos + 3]) << 8
                     | Int(dump[pos + 4]) << 16 | Int(dump[pos + 5]) << 24
            let type = dump[pos + 1]
            pos += 6
            guard pos + size <= dump.count else { ended = true; return }
            if type == 0x00 {  // YM2612 PCM data → append to the bank
                dataBank.append(contentsOf: dump[pos..<(pos + size)])
            }
            pos += size
        default:
            pos += operandCount(cmd)
            if pos > dump.count { ended = true }
        }
    }
}
