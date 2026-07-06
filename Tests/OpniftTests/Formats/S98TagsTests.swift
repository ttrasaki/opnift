import Foundation
import Testing
@testable import Opnift

@Suite("S98 TAG parsing")
struct S98TagsTests {

    /// Build a minimal S98 file: 0x20-byte header, optional TAG area, then a
    /// one-byte dump (0xFD = end).
    private func makeS98(version: UInt8, tag: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x20)
        bytes[0] = 0x53; bytes[1] = 0x39; bytes[2] = 0x38 // "S98"
        bytes[3] = 0x30 + version
        let tagOffset = tag.isEmpty ? 0 : 0x20
        let dumpOffset = 0x20 + tag.count
        func put(_ value: Int, at offset: Int) {
            bytes[offset]     = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
            bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
        }
        put(tagOffset, at: 0x10)
        put(dumpOffset, at: 0x14)
        bytes += tag
        bytes.append(0xFD)
        return Data(bytes)
    }

    @Test("v3 UTF-8 tag block (BOM) parses into lowercased keys")
    func v3UTF8() throws {
        var tag = Array("[S98]".utf8)
        tag += [0xEF, 0xBB, 0xBF] // BOM
        tag += Array("title=テーマ曲\nartist=作曲者\nGame=SAMPLE GAME\n".utf8)
        tag.append(0x00)
        let song = try S98(data: makeS98(version: 3, tag: tag))
        #expect(song.title == "テーマ曲")
        #expect(song.artist == "作曲者")
        #expect(song.game == "SAMPLE GAME") // key lowercased, value kept
    }

    @Test("v3 Shift-JIS tag block (no BOM) decodes Japanese values")
    func v3ShiftJIS() throws {
        var tag = Array("[S98]".utf8)
        tag += Array("title=".utf8)
        tag += [0x83, 0x5C, 0x83, 0x8B] // "ソル" in Shift-JIS
        tag += [0x0A]
        tag += Array("system=PC-9801\n".utf8)
        tag.append(0x00)
        let song = try S98(data: makeS98(version: 3, tag: tag))
        #expect(song.title == "ソル")
        #expect(song.system == "PC-9801")
    }

    @Test("v1 NUL-terminated title string becomes the title tag")
    func v1Title() throws {
        var tag = Array("SAMPLE OPENING".utf8)
        tag.append(0x00)
        let song = try S98(data: makeS98(version: 1, tag: tag))
        #expect(song.tags == ["title": "SAMPLE OPENING"])
    }

    @Test("v1 '[game] title' convention splits into game and title tags")
    func v1BracketedGame() throws {
        var tag: [UInt8] = []
        // "[SAMPLE GAME] オープニング" in Shift-JIS, the encoding real v1 rips use
        tag += Array("[SAMPLE GAME] ".utf8)
        tag += [0x83, 0x49, 0x81, 0x5B, 0x83, 0x76, 0x83, 0x6A, 0x83, 0x93, 0x83, 0x4F]
        tag.append(0x00)
        let song = try S98(data: makeS98(version: 1, tag: tag))
        #expect(song.game == "SAMPLE GAME")
        #expect(song.title == "オープニング")
    }

    @Test("v1 titles without a leading bracketed game name stay whole")
    func v1BracketNonSplit() {
        #expect(S98.v1Tags(title: "[unclosed opening") == ["title": "[unclosed opening"])
        #expect(S98.v1Tags(title: "[] no game name") == ["title": "[] no game name"])
        #expect(S98.v1Tags(title: "[GAME]") == ["title": "[GAME]"])
        #expect(S98.v1Tags(title: "TITLE [remix]") == ["title": "TITLE [remix]"])
        #expect(S98.v1Tags(title: "GAME[01] Opening") == ["title": "GAME[01] Opening"])
    }

    @Test("missing TAG area yields empty tags")
    func noTag() throws {
        let song = try S98(data: makeS98(version: 3, tag: []))
        #expect(song.tags.isEmpty)
        #expect(song.title == nil)
    }
}
