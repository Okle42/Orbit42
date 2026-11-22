# Orbit42

**One sphere, many AI brains.** Sign in with the AI provider accounts you already have — Claude, ChatGPT, Gemini, Grok — and every AI worker becomes a satellite orbiting the sphere. Click a satellite and its real terminal opens right there. No more hunting through a dozen terminal windows.

Part of the **42 series** by [Okle42](https://github.com/Okle42). [繁體中文說明](README.zh-TW.md)

> **Status: early (S1).** The sphere, new satellites and per-satellite terminals work; provider sign-in and the shared dashboard are next. See [docs/SPEC.md](docs/SPEC.md) (Chinese) for the roadmap.
>
> **License: source-available, not open source.** Read and try it for personal use; no commercial use or redistribution. See [LICENSE](LICENSE).

## How it works

- **Your brain, your account.** Orbit42 doesn't ship its own AI. Each satellite runs the provider's official agent — Claude Code (`claude`), OpenAI Codex CLI (`codex`), Google Antigravity CLI (`agy`) — so sign-in, tools, limits and updates are the provider's own. Orbit42 never sees your password or keys.
- **Satellites are real terminals.** Each one is a pseudo-terminal rendered with [xterm.js](https://xtermjs.org), so you see exactly what the agent shows in a normal terminal.
- **Background sessions too.** Claude Code sessions already running in the background can be pulled in as satellites (`claude attach`); closing the view leaves them running.
- **Shared core.** Session state, usage and audits come from the [ShoWork42](https://github.com/Okle42/ShoWork42) core library.

## Roadmap

| Stage | What |
|---|---|
| S1 | Sphere + "New satellite" + a real terminal per satellite ← now |
| S2 | Brain adapters: status, resume and usage for Claude → Codex → Antigravity (Gemini) → Grok |
| S3 | First-run sign-in with each provider's official login |
| S4 | Built-in throttle gate and fan guard (from [cool42](https://github.com/Okle42/cool42)) |
| S5 | Replaces the ShoWork42 command center |

## Build and run

Requires macOS 14+, Swift 6, and at least one provider CLI installed (e.g. Claude Code).

```bash
swift build
.build/debug/Orbit42
```

## Credits

[xterm.js](https://github.com/xtermjs/xterm.js) (MIT) and [three.js](https://github.com/mrdoob/three.js) (MIT) are vendored under `Web/vendor/` with their licenses.

## License

Source-available, **not open source** — © 2026 Okle42. You may read the code and run it for personal, non-commercial evaluation; commercial use, modification and redistribution are not permitted without written permission. See [LICENSE](LICENSE).
