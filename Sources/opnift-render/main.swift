import Foundation
import Opnift

// Render an S98 log to a 16-bit stereo WAV — the local harness tool that produces
// opnift_*.wav for `mise run compare` against the golden renders.
//
//   swift run opnift-render <input.s98> <output.wav> [seconds] [sampleRate]

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: opnift-render <input.s98|input.vgm> <output.wav> [seconds] [sampleRate]\n".utf8))
    exit(2)
}

let inputPath = arguments[1]
let outputPath = arguments[2]
let seconds = arguments.count > 3 ? (Double(arguments[3]) ?? 30.0) : 30.0
let sampleRate = arguments.count > 4 ? (Double(arguments[4]) ?? 44100.0) : 44100.0

func applyEnv(_ player: OPNStreamPlayer) {
    if let env = ProcessInfo.processInfo.environment["SSG_VOLUME"], let v = Double(env) {
        player.setSSGVolume(v)
    }
    if let env = ProcessInfo.processInfo.environment["FM_VOLUME"], let v = Double(env) {
        player.setFMVolume(v)
    }
}

do {
    let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
    let player = try OPNPlayer.make(data: data, sampleRate: sampleRate)
    applyEnv(player)

    let format = OPNPlayer.detectFormat(data).map { "\($0)".uppercased() } ?? "?"
    FileHandle.standardError.write(Data(
        "\(format)  out \(String(format: "%.1f", sampleRate)) Hz\n".utf8))

    let pcm = player.render(seconds: seconds)
    let wav = WAV.data(interleaved: pcm, channels: 2, sampleRate: Int(sampleRate))
    try wav.write(to: URL(fileURLWithPath: outputPath))

    FileHandle.standardError.write(Data(
        "wrote \(outputPath): \(pcm.count / 2) frames @ \(Int(sampleRate)) Hz (\(String(format: "%.1f", seconds))s)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
