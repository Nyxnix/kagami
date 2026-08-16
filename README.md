# kagami 鏡

Low-latency capture-card preview for macOS. Mirrors an AVerMedia Live Gamer
EXTREME 3 (or any AVFoundation capture card — edit `NAME`) into a window with
game audio, built the way OBS handles preview: push-model `AVCaptureSession`,
latest-frame-wins rendering, no player clock. Exists because mpv/ffplay can't
do this — players buffer, and mpv's demuxer can't read avfoundation devices
at all.

- Video: native-format frames → `AVSampleBufferDisplayLayer` (GPU, display-immediately)
- Audio: `AVCaptureAudioDataOutput` → `AVAudioPlayerNode`, ~20–40 ms
- mpv-style auto-hiding overlay: volume slider + resolution/framerate pickers
  populated from whatever the card advertises

## Build

```sh
./build.sh
```

Builds `~/Applications/kagami.app` (icon, Dock presence, its own
camera/mic permission identity — approve the prompts on first launch)
and links `~/.local/bin/kagami` to it for the terminal. The icon is
drawn by `icongen.swift`; delete `kagami.icns` to regenerate it.

Close OBS first — only one process gets the card. `--accurate` disables
the vivid P3 color tagging.

Hard-won AVFoundation gotchas are commented where they live in the source.
