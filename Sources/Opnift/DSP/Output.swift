import Foundation

/// Clamp a 32-bit mix sum into the 16-bit PCM range.
@inline(__always)
public func clampToInt16(_ value: Int32) -> Int16 {
    if value > 32767 { return 32767 }
    if value < -32768 { return -32768 }
    return Int16(value)
}

/// 16-bit PCM WAV container.
public enum WAV {

    /// Encode interleaved 16-bit samples as a canonical 44-byte-header PCM WAV.
    public static func data(interleaved samples: [Int16], channels: Int, sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var data = Data(capacity: 44 + dataSize)
        func appendU32(_ value: UInt32) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }
        func appendU16(_ value: UInt16) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendU32(16)                       // PCM fmt chunk size
        appendU16(1)                        // audio format = PCM
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(byteRate))
        appendU16(UInt16(blockAlign))
        appendU16(16)                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendU32(UInt32(dataSize))
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8((bits >> 8) & 0xFF))
        }
        return data
    }
}
