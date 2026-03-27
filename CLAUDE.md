# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture

macOS voice input tool: Objective-C thin frontend + Rust backend, linked via C FFI (cbindgen).

- `koe-core/` — Rust: config, ASR session management, FFI exports (`sp_core_*`)
- `koe-asr/` — Rust: Gemini Live API streaming ASR client
- `KoeApp/Reso/` — Obj-C: macOS integration (hotkeys, audio capture, overlay, status bar, clipboard paste)
- `KoeApp/project.yml` — XcodeGen config (generates `.xcodeproj`, do not edit `.xcodeproj` directly)

## Build

Requires: Rust toolchain, Xcode, XcodeGen (`brew install xcodegen`).

```
make build      # xcodegen + Rust + Xcode (full build)
make install    # build + replace /Applications/Reso.app + launch
make dmg        # build + create DMG at /tmp/
make release V=x.y.z  # build + DMG + GitHub release
```

## Key Conventions

- Rust FFI functions are prefixed `sp_core_*`, header auto-generated at `koe-core/target/koe_core.h`
- User config lives at `~/.koe/config.yaml` (YAML, hot-reloaded per session)
- Default system prompt embedded in `koe-core/src/default_system_prompt.txt`
- App is `LSUIElement=1` (no Dock icon, menu bar only)
- Code signing uses Apple Development certificate (team 648N996R87) — free Apple ID, local signing only
- `@DESIGN.md` contains full architecture rationale, state machine diagrams, and timing sequences
