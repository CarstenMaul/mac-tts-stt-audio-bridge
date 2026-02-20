# stt-tts-audio-bridge

Local macOS audio bridge with a virtual device, a local WebSocket API, and two speech engines:

- `apple`: built-in Apple TTS/STT (STT configured for on-device only)
- `elevenlabs`: realtime ElevenLabs TTS/STT

The bridge writes synthesized TTS audio to the virtual microphone stream by default, and reads STT source audio from the virtual speaker stream by default.

## Components

- `virtual_audio_driver` (`.driver` HAL plugin)
  - Virtual input: `Virtual Microphone`
  - Virtual output: `Virtual Speaker`
- `virtual_audio_bridge` (C++ core service)
  - localhost WebSocket server
  - config loading/validation
  - helper process management and IPC
- `engine_helper` (Swift executable)
  - Apple TTS/STT engine implementation
  - ElevenLabs realtime TTS/STT implementation
  - ring-buffer audio I/O
- `bridge_companion` (SwiftUI GUI test app)
  - connect/disconnect controls
  - mode selection
  - input text field + output transcript/event view

## Build

```bash
cmake -S . -B build
cmake --build build -j
```

Build outputs:

- `build/virtual_audio_bridge`
- `build/VirtualAudioBridge.driver`
- `build/engine_helper`

To build companion GUI binary:

```bash
cmake --build build --target bridge_companion_build
```

Companion output path:

- `swift/.build/release/bridge_companion`

## Driver install

```bash
./scripts/install_driver.sh build/VirtualAudioBridge.driver
```

Then verify in Audio MIDI Setup:

- `Virtual Audio Bridge`

### Driver signing requirement

On current macOS versions, HAL drivers that are ad-hoc signed are commonly rejected by AMFI/coreaudiod and will not show up in Audio MIDI Setup.

Check signature on the built driver binary:

```bash
codesign -dv --verbose=4 build/VirtualAudioBridge.driver/Contents/MacOS/VirtualAudioBridge 2>&1 | rg 'Signature=|TeamIdentifier='
```

If you see `Signature=adhoc` and/or `TeamIdentifier=not set`, sign with an Apple code-signing identity before install.

`install_driver.sh` now fails fast on ad-hoc signatures unless you explicitly override with:

```bash
ALLOW_UNSIGNED_DRIVER=1 ./scripts/install_driver.sh build/VirtualAudioBridge.driver
```

### Code signing setup

Recommended certificate types:

- local-only testing on your own Mac: `Mac Development` (may work, not for distribution)
- broader install reliability/distribution: `Developer ID Application`

Install the certificate and private key into your user `login` keychain, then verify identities:

```bash
security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db
```

Sign the built driver bundle (replace identity string):

```bash
codesign --force --deep --timestamp --options runtime \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  build/VirtualAudioBridge.driver
```

Verify the resulting signature:

```bash
codesign -dv --verbose=4 build/VirtualAudioBridge.driver/Contents/MacOS/VirtualAudioBridge 2>&1 | rg 'Signature=|Authority=|TeamIdentifier='
```

Expected: not `Signature=adhoc`, and `TeamIdentifier` is set.

## Configuration

The service requires `--config <path>`. The recommended location is:

- `~/.config/stt-tts-audio-bridge/config.json`

Example:

```bash
mkdir -p ~/.config/stt-tts-audio-bridge
cp config/config.example.json ~/.config/stt-tts-audio-bridge/config.json
```

Important config keys:

- `websocket.port`: required
- `session_defaults.mode`: `apple` or `elevenlabs`
- `session_defaults.stt_source`: `virtual_speaker` or `virtual_mic`
- `session_defaults.tts_target`: `virtual_mic`, `virtual_speaker`, or `both`
- `helper_path` (optional): path to `engine_helper` (defaults to sibling binary next to `virtual_audio_bridge`)

## Environment variables

If using ElevenLabs mode, set API key env var (or whatever `elevenlabs.api_key_env` specifies):

```bash
export ELEVENLABS_API_KEY=your_key_here
```

## CLI

```bash
# Validate config, helper path, rings, env requirements
./build/virtual_audio_bridge doctor --config ~/.config/stt-tts-audio-bridge/config.json

# Run websocket service
./build/virtual_audio_bridge service --config ~/.config/stt-tts-audio-bridge/config.json

# Debug modes
./build/virtual_audio_bridge debug-tone --seconds 10
./build/virtual_audio_bridge debug-loopback --seconds 10
```

Notes:

- Start the bridge service before connecting from the companion app.
- If bind fails, verify `websocket.port` is free.

## WebSocket API

Client -> bridge:

```json
{"type":"configure_session","mode":"apple","stt_source":"virtual_speaker","tts_target":"virtual_mic"}
{"type":"tts_start","utterance_id":"u1"}
{"type":"tts_chunk","utterance_id":"u1","text":"hello world"}
{"type":"tts_flush","utterance_id":"u1"}
{"type":"tts_cancel","utterance_id":"u1"}
{"type":"start_stt","stream_id":"s1","language":"en-US"}
{"type":"stop_stt","stream_id":"s1"}
{"type":"ping","id":"p1"}
```

Bridge -> client:

```json
{"type":"ready","version":"1"}
{"type":"session_config_applied","mode":"apple"}
{"type":"tts_status","utterance_id":"u1","status":"started","message":"..."}
{"type":"tts_alignment","utterance_id":"u1","chars":["h"],"char_start_ms":[0],"char_end_ms":[42]}
{"type":"stt_partial","stream_id":"s1","text":"hel"}
{"type":"stt_final","stream_id":"s1","text":"hello"}
{"type":"error","code":"...","message":"..."}
{"type":"pong","id":"p1"}
```

Protocol behavior:

- single active WebSocket client
- session must be configured before TTS/STT commands
- STT emits partial and final events

## Companion GUI

Launch after building:

```bash
swift/.build/release/bridge_companion
```

If no UI appears (process starts but window stays backgrounded), use the app-bundle launcher:

```bash
./scripts/launch_companion.sh
```

In GUI:

1. set host/port
2. connect
3. choose mode (`apple` or `elevenlabs`) and apply
4. send TTS text
5. start/stop STT

## Notes

- This is an MVP implementation; it favors developer iteration speed over production hardening.
- Apple STT requires macOS speech permissions and on-device recognition availability for selected locale.
- ElevenLabs realtime protocols may evolve; keep model/voice IDs current in config.

## Troubleshooting

### Virtual device does not appear

1. Verify the driver bundle is installed:
```bash
ls -ld /Library/Audio/Plug-Ins/HAL/VirtualAudioBridge.driver
```
2. Verify signature is not ad-hoc:
```bash
codesign -dv --verbose=4 /Library/Audio/Plug-Ins/HAL/VirtualAudioBridge.driver/Contents/MacOS/VirtualAudioBridge 2>&1 | rg 'Signature=|TeamIdentifier='
```
3. Check coreaudiod load logs:
```bash
/usr/bin/log show --last 20m --style compact --predicate 'process == "coreaudiod" AND eventMessage CONTAINS[c] "VirtualAudioBridge"' | tail -n 200
```
If logs contain `has no CMS blob` / `Unrecoverable CT signature issue`, the binary signature is being rejected.

### Do I need to restart CoreAudio?

Normally no manual restart is required after a full reboot.
After install/update, `scripts/install_driver.sh` already does:

```bash
sudo killall coreaudiod
```

So you usually do not need to restart any audio service manually beyond running the install script.
