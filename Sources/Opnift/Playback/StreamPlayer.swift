import Foundation

/// Base class for streaming OPN/OPNA players driven by a register-command log.
///
/// Subclasses (VGM, S98) only describe *how to decode the next command* — emitting
/// register writes and waits via `writeRegister`/`emitWait`, and handling end-of-log
/// via `loopOrEnd`. The pull/render machinery — timing accumulation, block-free
/// streaming resampling (each `ChipVoice` carries its phase across calls), multi-chip
/// mixing, looping and silence padding — lives here once, shared by every format.
///
/// All public timing is in *output frames* at `outputSampleRate`; the native chip rate
/// is fully internal to `ChipVoice`.
public class OPNStreamPlayer {

    /// One entry per emulated chip. Single-chip formats use one; VGM may use two.
    let voices: [ChipVoice]
    let outputSampleRate: Double

    /// Current read offset into the command log (`dump`). Subclasses advance it.
    var pos: Int = 0

    private var pendingFrames: Int = 0   // whole output frames waiting to be rendered
    private var fracCarry: Double = 0.0   // sub-frame remainder carried between waits

    /// Scratch accumulator for multi-chip mixing, reused across `renderBlock` calls so
    /// the stereo hot path stays allocation-free. Grown on demand, never shrunk.
    private var mixBuffer: [Int32] = []

    /// Output frames produced since the last reset/seek.
    public private(set) var renderedFrames: UInt64 = 0
    /// True once the log ended with no loop point (or a subclass forced a stop).
    public internal(set) var ended: Bool = false

    init(voices: [ChipVoice], outputSampleRate: Double) {
        self.voices = voices
        self.outputSampleRate = outputSampleRate
    }

    // MARK: - Subclass hooks

    /// Decode and apply one command at `pos`, advancing `pos`. Use `writeRegister` /
    /// `emitWait`, and call `loopOrEnd()` when the log's end marker is reached.
    func processEvent() { fatalError("subclass must override processEvent()") }

    /// Restart position for a new render pass. Subclasses set `pos` to the data start.
    func rewindToStart() { fatalError("subclass must override rewindToStart()") }

    // MARK: - Subclass helpers

    /// Queue a wait expressed in output frames (fractional carry preserved across calls).
    final func emitWait(outputFrames: Double) {
        fracCarry += outputFrames
        let whole = Int(fracCarry)
        fracCarry -= Double(whole)
        pendingFrames += whole
    }

    /// At end-of-log: jump to `loopPos` if the song loops, else mark the track ended.
    final func loopOrEnd(loopPos: Int?) {
        if let loopPos { pos = loopPos } else { ended = true }
    }

    /// Set the SSG→FM mix level on every chip (analysis / tuning).
    public func setSSGVolume(_ value: Double) { voices.forEach { $0.ssgVolume = value } }
    /// Set the FM mix level on every chip (analysis / tuning).
    public func setFMVolume(_ value: Double) { voices.forEach { $0.fmVolume = value } }

    // MARK: - Lifecycle

    /// Reset chips, resampler state and the command position to the song start.
    public func reset() {
        voices.forEach { $0.reset() }
        pendingFrames = 0
        fracCarry = 0.0
        renderedFrames = 0
        ended = false
        rewindToStart()
    }

    /// Seek to `targetFrame` output frames from the start: replay the command stream
    /// (applying register writes so chip state is correct at the seek point) without
    /// generating audio for the skipped span. Leaves `renderedFrames == targetFrame`.
    ///
    /// Approximation: the skipped span replays register writes but does *not* advance
    /// `chip.tick()`, so the chip's continuous analog state — envelope phase, LFO, SSG
    /// noise/tone counters — does not progress across the gap. Seeking into the middle of
    /// a sustained note therefore restarts it from the key-on attack rather than resuming
    /// at its true decayed level. For music playback this self-corrects within a frame or
    /// two and keeps seeks O(commands) instead of O(samples); it is not sample-accurate.
    public func seek(toFrame targetFrame: UInt64) {
        reset()
        while renderedFrames < targetFrame && !ended {
            if pendingFrames > 0 {
                let remaining = targetFrame - renderedFrames
                let n = min(UInt64(pendingFrames), remaining)
                pendingFrames -= Int(n)
                renderedFrames += n
            } else {
                processEvent()
            }
        }
    }

    // MARK: - Pull rendering

    /// Render exactly `frames` output frames into `buffer` (interleaved stereo Int16)
    /// starting at `offset` frames. Past end-of-song the remainder is filled with silence.
    public func render(into buffer: inout [Int16], frames: Int, offset: Int = 0) {
        var generated = 0
        while generated < frames {
            if pendingFrames > 0 {
                let n = min(pendingFrames, frames - generated)
                renderBlock(into: &buffer, at: offset + generated, count: n)
                generated += n
                pendingFrames -= n
                renderedFrames += UInt64(n)
            } else if ended {
                let base = (offset + generated) * 2
                for i in base..<((offset + frames) * 2) { buffer[i] = 0 }
                break
            } else {
                processEvent()
            }
        }
    }

    /// Mix every voice for `count` frames and clamp into the output buffer.
    private func renderBlock(into buffer: inout [Int16], at offset: Int, count: Int) {
        if voices.count == 1 {
            voices[0].render(frames: count, into: &buffer, offset: offset)
            return
        }
        let samples = count * 2
        if mixBuffer.count < samples {
            mixBuffer.append(contentsOf: repeatElement(0, count: samples - mixBuffer.count))
        }
        for i in 0..<samples { mixBuffer[i] = 0 }
        for voice in voices { voice.renderAdditive(frames: count, into: &mixBuffer, offset: 0) }
        for i in 0..<samples { buffer[offset * 2 + i] = clampToInt16(mixBuffer[i]) }
    }

    // MARK: - Offline convenience (CLI / golden compare)

    /// Render `seconds` of audio as interleaved 16-bit PCM by pulling the streaming path
    /// — identical DSP/timing to realtime playback, so CLI renders match what ships.
    public func render(seconds: Double) -> [Int16] {
        reset()
        let frames = Int((seconds * outputSampleRate).rounded())
        var buffer = [Int16](repeating: 0, count: frames * 2)
        render(into: &buffer, frames: frames)
        return buffer
    }
}
