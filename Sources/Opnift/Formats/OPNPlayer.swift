import Foundation

/// One entry point for playing any supported register-dump container.
///
/// Sniffs the file header to pick the right parser/player so callers don't branch on
/// file extension or magic bytes themselves:
///
/// ```swift
/// let player = try OPNPlayer.make(data: data, sampleRate: 44100)
/// player.render(into: &buffer, frames: n)
/// ```
public enum OPNPlayer {

    /// Supported container formats.
    public enum Format { case vgm, s98 }

    public enum Error: Swift.Error { case unknownFormat }

    /// Detect the container format from the leading magic bytes, or `nil` if unrecognized.
    public static func detectFormat(_ data: Data) -> Format? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 4, b[0] == 0x56, b[1] == 0x67, b[2] == 0x6D, b[3] == 0x20 { return .vgm } // "Vgm "
        if b.count >= 3, b[0] == 0x53, b[1] == 0x39, b[2] == 0x38 { return .s98 }                // "S98"
        return nil
    }

    /// Parse `data` and return a ready-to-render player, auto-detecting VGM vs S98.
    public static func make(data: Data, sampleRate: Double = 44100) throws -> OPNStreamPlayer {
        switch detectFormat(data) {
        case .vgm: return VGMPlayer(song: try VGM(data: data), sampleRate: sampleRate)
        case .s98: return S98Player(song: try S98(data: data), sampleRate: sampleRate)
        case nil:  throw Error.unknownFormat
        }
    }
}
