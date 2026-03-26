# Reso

A background-first macOS voice input tool. Press a hotkey, speak, and the corrected text is pasted into whatever app you're using.

Based on [Koe](https://github.com/missuo/koe) by [@missuo](https://github.com/missuo).

## How It Works

1. Press and hold the trigger key (default: **Fn**, configurable) — Reso starts listening
2. Audio streams in real-time to a cloud ASR service (Doubao/豆包 by ByteDance)
3. A floating status pill shows real-time interim recognition text as you speak
4. The ASR transcript is corrected by an LLM (any OpenAI-compatible API)
5. The corrected text is automatically pasted into the active input field

## Installation

### Release

Download the latest DMG from [GitHub Releases](https://github.com/yikZero/reso/releases/latest).

### Build from Source

#### Prerequisites

- macOS 13.0+
- Rust toolchain (`brew install rust`)
- Xcode with command line tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

#### Build

```bash
git clone https://github.com/yikZero/reso.git
cd reso
make build
```

#### Run

```bash
make run
```

## Configuration

All config files live in `~/.koe/` and are auto-generated on first launch:

```
~/.koe/
├── config.yaml          # Main configuration (ASR, LLM, hotkey, feedback)
├── dictionary.txt       # User dictionary (hotwords + LLM correction)
├── history.db           # Usage statistics (SQLite, auto-created)
├── system_prompt.txt    # LLM system prompt
└── user_prompt.txt      # LLM user prompt template
```

Refer to the [original Koe documentation](https://koe.li) for detailed configuration options.

## Permissions

Reso requires three macOS permissions:

| Permission | Why |
|---|---|
| **Microphone** | Captures audio for speech recognition |
| **Accessibility** | Simulates Cmd+V to auto-paste text |
| **Input Monitoring** | Detects the global hotkey trigger |

Grant them in **System Settings → Privacy & Security**.

## Credits

This project is a fork of [Koe](https://github.com/missuo/koe) by [@missuo](https://github.com/missuo). Thanks for the excellent work on the original project.

## License

MIT
