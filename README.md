# opnift
Pure-Swift OPN/OPNA (YM2203/YM2608) FM synthesizer for PC-88/PC-98 chiptunes.

Plays VGM and S98 register-dump logs through a from-scratch Swift port of the
ymfm FM+SSG core — no C dependencies, no system emulator. Output is checked
against golden ymfm/fmgen renders.

## Installation

Add Opnift to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ttrasaki/opnift.git", from: "0.2.0"),
],
```

and list it as a target dependency:

```swift
.target(name: "YourApp", dependencies: ["Opnift"]),
```

Requires Swift 6.0+ (macOS 12+, iOS 15+).

## Usage

### Render a song to PCM

`OPNPlayer.make` auto-detects VGM vs S98 from the file header and returns a
player. The simplest path renders a fixed duration to interleaved 16-bit stereo
PCM:

```swift
import Opnift

let data = try Data(contentsOf: url)              // a .vgm or .s98 file
let player = try OPNPlayer.make(data: data, sampleRate: 44100)

let pcm: [Int16] = player.render(seconds: 30)     // interleaved L,R,L,R…
```

### Stream for realtime playback

For an audio callback, pull fixed-size blocks. The streaming resampler carries
its phase across calls, so block boundaries are seamless; past the end of the
song the buffer is filled with silence.

```swift
let player = try OPNPlayer.make(data: data, sampleRate: 48000)

var buffer = [Int16](repeating: 0, count: frameCount * 2)
player.render(into: &buffer, frames: frameCount)

// player.reset()              // restart from the top
// player.seek(toFrame: 48000) // jump ~1s in (approximate; see docs)
// player.ended                // true once a non-looping song finishes
```

### Command-line renderer

The bundled `opnift-render` tool writes a WAV from a register-dump log:

```sh
swift run opnift-render <input.s98|input.vgm> <output.wav> [seconds] [sampleRate]
# e.g.
swift run opnift-render song.s98 song.wav 30 44100
```

## Supported formats

- **VGM** — YM2203 (OPN) and YM2608 (OPNA), including dual-chip logs.
- **S98** — YM2203 / YM2608.

## License & credits

Opnift is licensed under the BSD 3-Clause License (see [LICENSE](LICENSE)).

The FM and SSG cores are a Swift port of, and closely follow, **[ymfm](https://github.com/aaronsgiles/ymfm)**
by Aaron Giles (BSD 3-Clause), and are therefore a derivative work of ymfm. A couple
of lookup tables originate from MAME (via ymfm). ymfm's copyright notice and the full
list of ported parts are in [THIRD_PARTY](THIRD_PARTY).
