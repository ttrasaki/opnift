import Foundation

/// Clamp a 32-bit mix sum into the 16-bit PCM range.
@inline(__always)
public func clampToInt16(_ value: Int32) -> Int16 {
    if value > 32767 { return 32767 }
    if value < -32768 { return -32768 }
    return Int16(value)
}

/// Catmull-Rom cubic resampler from one rate to another.
///
/// Replaces the earlier linear version. Cubic interpolation preserves high-frequency
/// content much better than linear, which matters most when upsampling from a low
/// native rate (e.g. OPN at 27 kHz → 44.1 kHz output). The seam where Phase 1.5
/// swaps in a polyphase / output-rate fractional resampler to fully shape the high
/// end toward fmgen.
public func resampleLinear(_ input: [Int32], inputRate: Double, outputRate: Double) -> [Int32] {
    if input.isEmpty || inputRate == outputRate { return input }
    let ratio = inputRate / outputRate
    let outputCount = Int(Double(input.count) / ratio)
    var output = [Int32]()
    output.reserveCapacity(outputCount)
    let last = input.count - 1
    for i in 0..<outputCount {
        let position = Double(i) * ratio
        let idx = Int(position)
        let t = position - Double(idx)
        let p0 = Double(input[max(idx - 1, 0)])
        let p1 = Double(input[idx])
        let p2 = Double(input[min(idx + 1, last)])
        let p3 = Double(input[min(idx + 2, last)])
        // Catmull-Rom coefficients
        let c1 = (p2 - p0) * 0.5
        let c2 = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c3 = (p3 - p0) * 0.5 + 1.5 * (p1 - p2)
        output.append(Int32((((c3 * t + c2) * t + c1) * t + p1).rounded()))
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
