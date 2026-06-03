# ManyAgents

A native macOS chat-style frontend for [Claude Code](https://claude.com/claude-code) — multiple agents across multiple projects, no terminal.

ManyAgents is the sibling to [ClaudeDeck](https://github.com/stulogy/claudedeck). Where ClaudeDeck embeds the `claude` CLI in a SwiftTerm PTY and parses the JSONL transcripts to infer status, ManyAgents drives `claude` in `--input-format stream-json --output-format stream-json` mode — bidirectional JSON over stdio. The conversation renders natively (markdown text, tool-use cards, image previews), status is read directly from the event stream, and the input composer is a real text field instead of a terminal prompt.

> **No API key needed.** ManyAgents shells out to the `claude` CLI for every call, so it inherits whatever auth you already have set up — your Claude Max subscription, an API key, or `claude login`'s OAuth tokens. If `claude` isn't installed or logged in, ManyAgents shows a one-screen onboarding with the exact commands to run.

## Why a separate app

The CLI-in-a-PTY approach (ClaudeDeck) gives you 100% of Claude Code's TUI features but the terminal is slow, escape-code parsing is fragile, and you can't easily layer features like voice input or a structured agent dashboard. ManyAgents trades a few CLI-only features (slash commands, the queued-messages TUI, the subagent picker) for:

- Native chat UX: streaming markdown text, tool calls as cards, instant status indicators with a Claude-Code-style status line (`Warping… (2m 19s · ↓ 8.9k tokens · writing)`).
- **Voice input** via on-device Apple Speech recognition (push-to-talk; no network).
- **Image paste** — ⌘V a screenshot, it gets downscaled to the Anthropic vision sweet-spot (≤1568px long side), deduped, and sent as a multimodal block.
- **Auto-generated tab titles** via a quick Haiku call after the first real exchange — same name persists across launches.
- **Card overview** — flip the sidebar toggle to see every agent across every project as a grid, sorted by status.
- **Session resume** — every agent's `--resume` id is persisted; on next launch the prior conversation is replayed inline into the conversation pane (read from the on-disk JSONL transcript).
- Full programmatic control over message rendering, history, persistence.

## Quick start

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `claude` CLI must be on `PATH` or in one of the standard locations (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.claude/local`, `~/.bun/bin`, `~/.npm-global/bin`).

```sh
git clone git@github.com:stulogy/manyagents.git
cd manyagents
xcodegen generate
open ManyAgents.xcodeproj
```

Build & Run from Xcode (⌘R) or:

```sh
xcodebuild -project ManyAgents.xcodeproj -scheme ManyAgents -configuration Debug build
open build/Build/Products/Debug/ManyAgents.app
```

The `.xcodeproj` is regenerated from `project.yml` by XcodeGen and isn't committed — run `xcodegen generate` again after pulling.

You do **not** need a paid Apple Developer account to build, run, or use ManyAgents — ad-hoc signing is the default and works fine for personal use. The only reason to sign with a developer cert is to stop macOS from re-prompting for keychain access on every rebuild during daily development (copy `Local.xcconfig.override.example` to `Local.xcconfig.override` and set your team ID).

## How it works

Each user prompt spawns a fresh `claude` subprocess in headless stream-json mode:

```
claude --print --input-format stream-json --output-format stream-json --verbose --permission-mode acceptEdits --resume <session_id>
```

`ClaudeBridge` (in `Services/`) owns the `Process`, writes the user message to stdin as JSON, parses stdout newline-delimited events into typed `BridgeEvent`s, then lets the process exit. The UI subscribes via Combine and renders messages as they land.

Each turn = one process. Cleaner than holding a long-running PTY: less memory, no zombie processes, and `--resume` actually picks up the prior conversation because we hand claude a prompt to run against immediately. The claude `session_id` lives on the owning `AgentSession` and is persisted in UserDefaults so subsequent turns resume the same conversation.

## Features

- **Projects sidebar** with status chips (waiting / running / idle) and a row/card view toggle.
- **Per-project tabs** with auto-generated 2-4 word titles, drag-to-reorder, right-click → Rename / Reset to Auto-Name / Close.
- **Streaming response render** with markdown, tool-use cards (Bash, Edit, Read, Grep, MultiEdit, Write, Task, WebFetch…), and an indented tool-result display modeled on the TUI's `└` corner glyph.
- **Composer** with paste-aware image input, push-to-talk voice dictation, ⌘N new session, ↩ to send, ⇧↩ for newline.
- **Live status line** during a turn: rotating verb (Spelunking, Warping, Brewing, Quantumizing…), elapsed time, output-token counter, current phase (thinking / writing / running Bash / editing / reading / searching).
- **Card overview** of every agent across every project, sorted by status.

## Privacy

- Tab auto-naming uses your existing Claude Code authentication via a one-shot `claude -p` call — no separate API key managed by ManyAgents.
- Voice input uses Apple's on-device Speech framework with `requiresOnDeviceRecognition = true` — audio never leaves your machine. Requires Speech Recognition + Microphone permissions, plus Dictation enabled in System Settings.
- Pasted images are downscaled locally before being sent to `claude`; they go wherever claude sends them (which respects your Claude Code config).
- Session transcripts, snapshots, and titles live in `~/Library/Application Support/<bundle id>/` (UserDefaults) and `~/.claude/projects/` (managed by `claude` itself).

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- Built on top of [Claude Code](https://claude.com/claude-code).
- Sibling to [ClaudeDeck](https://github.com/stulogy/claudedeck) — the same brand colors, fonts, and project layout, just a different transport.
