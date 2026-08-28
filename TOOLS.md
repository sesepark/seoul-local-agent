# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup: camera names and locations, SSH hosts and aliases, preferred TTS voices, speaker/room names, device nicknames, anything environment-specific.

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.

## Related

- [Agent workspace](/concepts/agent-workspace)

## Local Automation Connectors

- Local LLM: Ollama native API at `http://127.0.0.1:11434`; use `ollama/qwen36-fable-27b-mtp-q4:latest` through OpenClaw.
- Gmail: use `gog` after OAuth authorization. Read-only queries and summaries are the default.
- Notion: use `ntn` with `NOTION_API_TOKEN`; the integration must be shared with each intended page or data source.
- Slack: Socket Mode is configured with DM pairing. It needs `SLACK_APP_TOKEN` and `SLACK_BOT_TOKEN` in the Gateway environment before it can connect.
