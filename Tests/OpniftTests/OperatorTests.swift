import Foundation
import Testing
@testable import Opnift

@Suite("FM operator")
struct OperatorTests {

    @Test("output is periodic over one waveform cycle")
    func periodicity() {
        var op = Operator()
        op.phaseIncrement = 1 << Operator.waveformShift // exactly 1024 samples / cycle
        var cycle = [Int32]()
        for _ in 0..<1024 { cycle.append(op.next()) }
        for i in 0..<1024 { #expect(op.next() == cycle[i]) }
    }

    @Test("a bare operator approximates a sine")
    func approximatesSine() {
        var op = Operator()
        op.phaseIncrement = 1 << Operator.waveformShift // 1024 samples / cycle
        let scale = 2042.0
        var maxError = 0.0
        for i in 0..<1024 {
            let actual = Double(op.next())
            // The quarter-wave table samples at (i + 0.5); match that to isolate
            // log-domain quantization from a half-bin phase offset.
            let expected = sin((Double(i) + 0.5) * 2.0 * .pi / 1024.0) * scale
            maxError = max(maxError, abs(actual - expected))
        }
        #expect(maxError < 8.0) // a few LSB out of ~2042 full scale
    }

    @Test("DC offset over a full cycle is zero")
    func dcIsZero() {
        var op = Operator()
        op.phaseIncrement = 1 << Operator.waveformShift
        var sum: Int64 = 0
        for _ in 0..<1024 { sum += Int64(op.next()) }
        #expect(sum == 0) // positive and negative half-waves cancel exactly
    }

    @Test("setFrequency yields the expected samples-per-cycle")
    func setFrequency() {
        var op = Operator()
        op.setFrequency(440.0, sampleRate: 44100.0)
        let expected = UInt32((440.0 / 44100.0 * Double(1 << Operator.phaseBits)).rounded())
        #expect(op.phaseIncrement == expected)
    }
}
