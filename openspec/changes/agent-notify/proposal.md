## Why

We run parallel OpenCode agents across multiple servers (each in its own git worktree via tmux). When an agent finishes, errors, needs input (askquestion tool), or requests permission, there is no notification — we only discover the state change by manually checking each tmux window. This creates dead time between "agent needs attention" and "human notices," which compounds across multiple agents and servers.

## What Changes

- **New OpenCode plugin** (`agent-notify`): A global plugin loaded by every OpenCode instance that detects session state changes (idle, error, question, permission) and emits structured events to an external notification pipeline.
- **New per-server daemon** (`agent-notify-daemon`): A standalone process on each server that receives events from plugins via a shared SQLite registry, manages Telegram bot polling (getUpdates), and routes responses back to the correct OpenCode instance via localhost HTTP.
- **New Mac listener** (`agent-notify-listener`): A lightweight process on the user's main machine that subscribes to events via ntfy, shows macOS notifications (osascript), and sends ACKs back so the daemon can decide whether to escalate to Telegram.
- **Notification escalation**: Events first attempt macOS notification (immediate, informational). If the Mac doesn't ACK within a configurable timeout, the daemon escalates to Telegram with rich inline keyboard buttons for responding.
- **Telegram two-way responses**: The Telegram notification includes inline keyboard buttons (for askquestion options, permission allow/deny, retry/abort for errors). The daemon polls getUpdates, parses callback queries, and routes responses to the correct OpenCode session via the local HTTP API.
- **Install script integration**: The dotfiles install script sets up all components — plugin symlink, daemon as a system service (launchd on macOS, systemd on Linux), and Mac listener (launchd, main machine only). Includes interactive first-time Telegram bot setup.

## Capabilities

### New Capabilities
- `event-detection`: OpenCode plugin that classifies session events (idle, error, question, permission) and writes structured events to a shared SQLite registry with session-to-port mapping.
- `notification-daemon`: Per-server daemon that reads the SQLite registry, sends events to ntfy for Mac delivery, manages escalation timers, sends Telegram notifications, polls getUpdates for responses, and routes them back to OpenCode instances via localhost.
- `mac-listener`: Lightweight macOS process that subscribes to ntfy events, displays native macOS notifications, and sends ACKs to suppress/delay Telegram escalation.
- `telegram-integration`: Two-way Telegram communication — sending rich notifications with inline keyboards, polling for callback queries and text replies, routing responses to the correct session and API endpoint (prompt for messages, permissions endpoint for approvals).
- `install-setup`: Install script integration with interactive Telegram bot setup, platform-specific service installation (launchd/systemd), config management, and main-machine detection.

### Modified Capabilities
<!-- No existing capabilities are being modified. -->

## Impact

- **New files in dotfiles**: `agent-notify/` directory with daemon, listener, config, and shared modules. Plugin in `opencode/plugins/`.
- **New system services**: launchd plists (macOS) and systemd user units (Linux) for the daemon; additional launchd plist for the Mac listener on the main machine.
- **New dependencies**: Bun runtime (already available via OpenCode), `bun:sqlite` (built-in), ntfy.sh (external service, free tier or self-hosted).
- **External services**: Telegram Bot API (one bot per server), ntfy.sh (message bus between servers and Mac).
- **Install script**: Extended with agent-notify setup section, interactive Telegram configuration, and platform-specific service management.
