import Foundation

/// Clamp a 32-bit mix sum into the 16-bit PCM range.
@inline(__always)
public func clampToInt16(_ value: Int32) -> Int16 {
    if value > 32767 { return 32767 }
    if value < -32768 { return -32768 }
    return Int16(value)
}

/// Linear resampler from one rate to another.
///
/// This is the simplest correct resampler and the seam where Phase 1.5 swaps in a
/// polyphase / output-rate fractional resampler to shape the high end toward fmgen.
/// Kept linear for now so the output path works end-to-end and feeds `compare.py`.
public func resampleLinear(_ input: [Int32], inputRate: Double, outputRate: Double) -> [Int32] {
    if input.isEmpty || inputRate == outputRate { return input }
    let ratio = inputRate / outputRate
    let outputCount = Int(Double(input.count) / ratio)
    var output = [Int32]()
    output.reserveCapacity(outputCount)
    for i in 0..<outputCount {
        let position = Double(i) * ratio
        let index = Int(position)
        let frac = position - Double(index)
        let a = Double(input[index])
        let b = index + 1 < input.count ? Double(input[index + 1]) : a
        output.append(Int32((a + (b - a) * frac).rounded()))
    }
    return output
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

public extension OPNA {

    /// Render `count` stereo samples at the chip's native rate (unclamped Int32).
    mutating func renderNative(sampleCount count: Int) -> (left: [Int32], right: [Int32]) {
        var left = [Int32](repeating: 0, count: count)
        var right = [Int32](repeating: 0, count: count)
        for i in 0..<count {
            let (l, r) = tick()
            left[i] = l
            right[i] = r
        }
        return (left, right)
    }

    /// Render `seconds` of audio, resampled to `sampleRate`, as interleaved 16-bit PCM.
    mutating func render(seconds: Double, sampleRate target: Double = 44100) -> [Int16] {
        let nativeCount = Int((seconds * sampleRate).rounded())
        let (nativeL, nativeR) = renderNative(sampleCount: nativeCount)
        let outL = resampleLinear(nativeL, inputRate: sampleRate, outputRate: target)
        let outR = resampleLinear(nativeR, inputRate: sampleRate, outputRate: target)
        let n = min(outL.count, outR.count)
        var interleaved = [Int16]()
        interleaved.reserveCapacity(n * 2)
        for i in 0..<n {
            interleaved.append(clampToInt16(outL[i]))
            interleaved.append(clampToInt16(outR[i]))
        }
        return interleaved
    }
}
