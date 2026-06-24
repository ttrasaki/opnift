import Testing
@testable import Opnift

@Suite("OPN operator tables")
struct TablesTests {

    @Test("log-sin table has 256 entries with known anchors")
    func logSinAnchors() {
        #expect(OpnTables.logSin.count == 256)
        #expect(OpnTables.logSin[0] == 2137)   // steepest attenuation near phase 0
        #expect(OpnTables.logSin[255] == 0)     // peak of the sine, no attenuation
        // Monotonically non-increasing across the quarter wave.
        for i in 1..<256 {
            #expect(OpnTables.logSin[i] <= OpnTables.logSin[i - 1])
        }
    }

    @Test("exp table has 256 entries with known anchors")
    func expAnchors() {
        #expect(OpnTables.exp.count == 256)
        #expect(OpnTables.exp[0] == 0)
        #expect(OpnTables.exp[255] == 1018)
        // Strictly increasing fractional mantissa.
        for i in 1..<256 {
            #expect(OpnTables.exp[i] > OpnTables.exp[i - 1])
        }
    }

    @Test("absSinAttenuation mirrors within the half wave")
    func absSinMirror() {
        // Phase 0 and phase 0x1FF map to the same quarter-wave endpoint.
        #expect(OpnTables.absSinAttenuation(0) == OpnTables.logSin[0])
        #expect(OpnTables.absSinAttenuation(0x1FF) == OpnTables.logSin[0])
        #expect(OpnTables.absSinAttenuation(0xFF) == OpnTables.logSin[255])
        #expect(OpnTables.absSinAttenuation(0x100) == OpnTables.logSin[255])
    }

    @Test("attenuationToVolume: zero attenuation is near full scale and halves per octave")
    func attenuationToVolume() {
        let full = OpnTables.attenuationToVolume(0)
        #expect(full == 2042)
        // Each 0x100 of attenuation is one octave (a halving).
        #expect(OpnTables.attenuationToVolume(0x100) == full / 2)
        #expect(OpnTables.attenuationToVolume(0x200) == full / 4)
    }
}
