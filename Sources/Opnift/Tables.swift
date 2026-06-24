import Foundation

/// Core lookup tables for the OPN/OPNA FM operator.
///
/// FM synthesis in the Yamaha OPN family works in the **logarithmic (attenuation)
/// domain**: the sine is stored as `-log2(sin)` and the final conversion back to a
/// linear amplitude is a `2^-x` lookup. Summing two attenuations = multiplying two
/// gains, which is why total level, envelope and modulation all add cheaply.
///
/// These tables are *generated* from the canonical formulas (not copied) so they can
/// be checked for numeric parity against ymfm's hard-coded `s_sin_table` /
/// `s_power_table`. Anchor values are pinned in the tests; full byte-for-byte parity
/// vs ymfm is verified once ymfm's arrays are pulled in locally (see Phase 1 plan).
///
/// Generated once as immutable `let`s (per the perf notes: fixed tables, no rebuild).
public enum OpnTables {

    /// Quarter-wave log-sin attenuation table, 256 entries.
    ///
    /// `logSin[i] = round(-log2(sin((i + 0.5) · π/2 / 256)) · 256)` — a 4.8 fixed-point
    /// log2 value (×256). `logSin[0] == 2137` (steepest), `logSin[255] == 0` (peak).
    public static let logSin: [UInt16] = (0..<256).map { i in
        let angle = (Double(i) + 0.5) * (.pi / 2.0) / 256.0
        let value = (-log2(sin(angle)) * 256.0).rounded()
        return UInt16(value)
    }

    /// Exponential (attenuation → linear) table, 256 entries.
    ///
    /// Stores the fractional part of `2^(x/256)` scaled by 1024 (10-bit mantissa with an
    /// implied leading 1). `exp[0] == 0`, `exp[255] == 1018`. Restore the mantissa with
    /// `exp[i] | 0x400` → range `[1024, 2047]`.
    public static let exp: [UInt16] = (0..<256).map { i in
        let value = ((exp2(Double(i) / 256.0) - 1.0) * 1024.0).rounded()
        return UInt16(value)
    }

    /// Look up `|sin|` attenuation for a phase, in the log2 domain.
    ///
    /// `phase` low 8 bits index the quarter wave; bit 8 mirrors within the half wave.
    /// (Sign / second half is applied by the caller after `attenuationToVolume`.)
    @inline(__always)
    public static func absSinAttenuation(_ phase: UInt32) -> UInt16 {
        var index = phase & 0xff
        if (phase & 0x100) != 0 {
            index ^= 0xff // mirror: the second quarter runs the table backwards
        }
        return logSin[Int(index)]
    }

    /// Convert a total attenuation (log domain) back to a linear amplitude.
    ///
    /// Low 8 bits = fractional attenuation (inverted index into `exp`), high bits =
    /// integer octaves of attenuation (a right shift). Result is an unsigned magnitude
    /// with ~13 bits of range; `attenuationToVolume(0) == 2042` (near full scale).
    @inline(__always)
    public static func attenuationToVolume(_ attenuation: UInt32) -> UInt16 {
        let octaves = Int(attenuation >> 8)
        if octaves >= 12 { return 0 } // mantissa is ~11-bit; beyond this it's silence
        let fractional = Int((attenuation & 0xff) ^ 0xff)
        let mantissa = UInt32(exp[fractional] | 0x400) // restore implied leading 1
        return UInt16(mantissa >> octaves)
    }
}
