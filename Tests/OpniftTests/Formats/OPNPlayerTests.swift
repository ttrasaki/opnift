import Foundation
import Testing
@testable import Opnift

@Suite("OPNPlayer facade")
struct OPNPlayerTests {

    @Test("detectFormat recognizes VGM and S98 magic, rejects the rest")
    func detect() {
        #expect(OPNPlayer.detectFormat(Data([0x56, 0x67, 0x6D, 0x20])) == .vgm) // "Vgm "
        #expect(OPNPlayer.detectFormat(Data([0x53, 0x39, 0x38, 0x33])) == .s98) // "S983"
        #expect(OPNPlayer.detectFormat(Data([0x52, 0x49, 0x46, 0x46])) == nil)  // "RIFF"
        #expect(OPNPlayer.detectFormat(Data()) == nil)
    }

    @Test("make throws unknownFormat on unrecognized data")
    func unknown() {
        #expect(throws: OPNPlayer.Error.unknownFormat) {
            _ = try OPNPlayer.make(data: Data([0x00, 0x01, 0x02, 0x03]))
        }
    }
}
