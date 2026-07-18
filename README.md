# vLLM Metal Desktop

A native macOS app for running LLMs locally with [vllm-metal](https://github.com/vllm-project/vllm-metal) —
the vLLM engine on Apple Silicon.

Chat with local models, browse and download them from Hugging Face, deploy multiple
OpenAI-compatible servers side by side, and manage the engine — all in a native
SwiftUI app built for the Mac.

## Features

- **Chat** — streaming conversations with reasoning-model support (thinking sections),
  image & file attachments for vision models, Markdown rendering, per-message stats.
- **Models** — Hugging Face browser with VRAM-fit guidance for your Mac, real
  byte-accurate download progress, and local cache management.
- **Server** — deploy multiple models at once (one port each), live engine logs,
  a native API explorer for every OpenAI/Anthropic-compatible endpoint, and
  ready-to-paste examples for wiring up other apps.
- **Engine** — one-click install and updates of vllm-metal, release notes with
  contributors, version switching, and health checks.
- **Native** — Liquid Glass design, light/dark, adjustable text size. No Electron.

## Requirements

- Apple Silicon Mac (arm64)
- macOS 14 or later
- Xcode Command Line Tools (for the engine install)

## Install

Download the latest `.dmg` from [Releases](https://github.com/ricky-chaoju/vllm-metal-desktop/releases),
drag the app to Applications, and follow the in-app setup — it installs the engine and
a starter model for you.

## Build from source

```bash
git clone https://github.com/ricky-chaoju/vllm-metal-desktop.git
cd vllm-metal-desktop
open "vLLM Metal Desktop.xcodeproj"
```

Build the `vLLM Metal Desktop` scheme with Xcode 26 or later (the app targets
macOS 14, newer APIs are availability-gated). Core logic lives in the `VMDCore`
Swift package:

```bash
cd VMDCore && swift test
```

## Architecture

| Layer | What it does |
| --- | --- |
| `VMDCore` | Engine lifecycle, Hugging Face client, OpenAI/Anthropic API client, process supervision — pure Swift, fully tested |
| `vLLM Metal Desktop/Features` | SwiftUI feature surfaces: Chat, Models, Server, Engine, Hardware, Settings |
| `vLLM Metal Desktop/DesignSystem` | Liquid Glass components, theme, layout primitives |

The engine itself lives in a Python virtualenv managed by the app
(`~/.venv-vllm-metal`); models go to the standard Hugging Face cache so other
tools can share them.

## License

[Apache-2.0](LICENSE)
