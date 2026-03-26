## Context

We use a worktree-per-feature workflow with OpenCode agents running in parallel across multiple servers, each in its own tmux window. Agents run autonomously — building, testing, asking questions — but there is no notification mechanism when they need human attention. The user works from a MacBook, either locally or SSH'd into servers.

OpenCode's plugin system provides event hooks (`session.idle`, `session.error`, `permission.asked`, `message.part.updated`) and an SDK client per instance. Each OpenCode instance runs its own HTTP server on a random port. The `askquestion` tool (PR #5958) attaches `waiting` metadata to tool parts when the agent needs user input.

Multiple OpenCode instances can run simultaneously on a single server (one per worktree), and across multiple servers. Each server has its own Telegram bot token (one bot per server, avoiding the `getUpdates` single-consumer limitation).

## Goals / Non-Goals

**Goals:**
- Notify the user on macOS (native notification center) when any agent needs attention — immediately
- Escalate to Telegram (phone) with rich response capability if the Mac doesn't acknowledge within a configurable delay
- Support two-way interaction via Telegram: inline keyboard buttons for askquestion options, permission allow/deny, error retry/abort, and free-text replies
- Route Telegram responses back to the correct OpenCode session on the correct server via localhost HTTP
- Handle multiple concurrent OpenCode instances per server sharing a single Telegram bot token
- Install via dotfiles install script with interactive first-time Telegram setup
- Run daemon and listener as platform-native services (launchd/systemd)
- Detect and clean up stale sessions (crashed OpenCode instances)
- Update Telegram notifications when a session is answered from the TUI directly

**Non-Goals:**
- Global cross-server visibility dashboard or coordination
- Web UI for managing agents
- Notifications for routine progress (only state transitions that need attention)
- Supporting notification channels beyond macOS native + Telegram
- Running on Windows

## Decisions

### 1. Split architecture: Plugin + Daemon + Mac Listener

**Decision**: Three separate components rather than a monolithic plugin.

**Rationale**: The plugin runs inside OpenCode (one per instance). Telegram's `getUpdates` allows only one consumer per bot token. Multiple instances per server would fight over polling. Separating the daemon solves this cleanly — plugins are fire-and-forget event emitters, the daemon handles all Telegram I/O and response routing. The Mac listener is a third component because macOS notifications must originate from the Mac itself, and the Mac may not be the machine running the agents.

**Alternatives considered**:
- All-in-plugin with poller election (lock file, registry): More self-contained but introduces complex coordination — lock acquisition, poller failover, stale lock recovery. Rejected for fragility.
- One Telegram bot per OpenCode instance: Eliminates polling contention but creates dozens of bots messaging the user. Rejected for UX noise.

### 2. SQLite as the shared registry

**Decision**: Use `bun:sqlite` (built into Bun) for the shared registry between plugins and daemon on each server.

**Rationale**: Multiple plugin instances write concurrently (session registration, event logging). JSON files have race conditions under concurrent writes. SQLite handles concurrent access natively with WAL mode. Bun ships with `bun:sqlite` so there are zero additional dependencies.

**Schema**:
```
sessions:
  id TEXT PRIMARY KEY        -- opencode session ID
  port INTEGER               -- localhost port of the OC server
  project TEXT               -- project name
  worktree TEXT              -- worktree/branch name
  created_at INTEGER         -- timestamp
  last_seen INTEGER          -- heartbeat timestamp for stale detection

events:
  id TEXT PRIMARY KEY        -- event UUID
  session_id TEXT            -- FK to sessions
  type TEXT                  -- "done" | "error" | "question" | "permission"
  payload TEXT               -- JSON: question text, options, error message, etc.
  telegram_msg_id INTEGER    -- Telegram message ID (set after sending)
  status TEXT                -- "pending" | "mac_acked" | "tg_sent" | "responded" | "stale"
  created_at INTEGER
  responded_at INTEGER
```

### 3. ntfy.sh as the server-to-Mac message bus

**Decision**: Use ntfy.sh to deliver events from server daemons to the Mac listener. Two topics: one for events, one for ACKs.

**Rationale**: Servers may not be able to reach the Mac directly (different networks, NAT). ntfy.sh is a public pub/sub service that requires no open ports on either end — servers POST events, Mac subscribes via SSE. It's free, self-hostable, and the payload is just JSON. The ACK topic allows the Mac to confirm receipt, enabling the daemon to decide whether to escalate to Telegram.

**Alternatives considered**:
- Direct HTTP from server to Mac (requires Mac to be reachable, Tailscale/VPN): Simpler but not always possible. Could be added as an optional transport later.
- Telegram as the only channel (install Telegram Desktop on Mac): User explicitly doesn't want Telegram Desktop.

### 4. Notification escalation with delay timers

**Decision**: Always attempt macOS notification first (via ntfy → Mac listener → osascript). Start a configurable delay timer. If the Mac listener ACKs within the timeout, suppress or further delay the Telegram notification. If no ACK, send Telegram.

**Delay defaults**:
- `question`: 30s (high urgency — agent is blocked)
- `permission`: 30s (high urgency — agent is blocked)
- `error`: 60s (medium urgency — agent has stopped)
- `done`: 120s (low urgency — agent finished, ready for review)

**Rationale**: Avoids duplicate notifications when the user is at their Mac. The delay is short enough that phone notification arrives quickly if the user is away.

### 5. Callback data encoding with short session ID prefix

**Decision**: Use first 8 characters of the session UUID in Telegram `callback_data` to stay within the 64-byte limit.

**Format**: `r|<8-char-prefix>|<option-index>` for responses, `p|<8-char-prefix>|a` or `p|<8-char-prefix>|d` for permissions.

**Rationale**: 8 hex chars = 4 billion possible values. Collision probability across a few dozen concurrent sessions is negligible. The daemon maps the prefix back to the full session ID via the SQLite registry.

### 6. One Telegram bot per server

**Decision**: Each server gets its own Telegram bot token. All instances on that server share the token (plugins send, daemon polls).

**Rationale**: Telegram's `getUpdates` supports only one consumer per token. One bot per server means one daemon per server polls without contention. The user receives messages from multiple bots but each is clearly labeled with the server name in the message text.

### 7. Platform-native service management

**Decision**: Use launchd (macOS) and systemd user units (Linux) instead of tmux for keeping the daemon alive.

**Rationale**: The daemon is a background process that should survive terminal sessions, reboots, and SSH disconnects. System service managers provide auto-restart, logging, and boot-start. tmux is for interactive work. The install script generates and installs the appropriate service definition per platform.

### 8. Stale session detection via heartbeat

**Decision**: Plugins periodically update `last_seen` in the SQLite registry. The daemon marks sessions as stale if `last_seen` is older than a threshold (e.g., 60s). Stale events in Telegram are updated via `editMessageText`.

**Rationale**: If an OpenCode instance crashes, its sessions remain in the registry pointing to a dead port. Without cleanup, the daemon would try to route responses to a dead server. The heartbeat pattern is simple and requires no IPC between plugin and daemon beyond the shared SQLite file.

## Risks / Trade-offs

- **ntfy.sh availability**: If ntfy.sh is down, Mac notifications fail. Telegram still works (sent directly). → Mitigation: Support self-hosted ntfy as a config option. The daemon sends Telegram regardless after the delay, so ntfy failure only means you lose the Mac-first notification for that event.

- **SQLite under heavy concurrent writes**: Many plugins writing simultaneously could cause WAL checkpoint delays. → Mitigation: Writes are small and infrequent (session registration, event creation). SQLite WAL mode handles this well at our scale (dozens, not thousands of writes/sec).

- **Telegram 64-byte callback_data limit**: Complex payloads won't fit. → Mitigation: Use short prefixes + option indices. Full context lives in SQLite, not in the callback.

- **Plugin can't discover its own port**: The SDK client has the base URL internally but may not expose it. → Mitigation: Spike during implementation. Fallback: parse from process listening sockets via `lsof` or inspect the SDK client object at runtime.

- **Event payload shape undocumented**: The `event` object in plugin hooks has `type` but the full shape (session ID, message parts) is not documented. → Mitigation: Spike during implementation to log event payloads. Fallback: use `client.session.list()` and `client.session.messages()` to query state when events fire.

- **Mac listener as launchd service**: launchd may throttle the service if it restarts too frequently. → Mitigation: The listener is a long-running SSE subscription, not a polling loop. It should rarely need restarting.

- **Multiple bots messaging the user**: Could be noisy if many servers are active. → Mitigation: Clear labeling (server name in each message). Users can mute individual bots in Telegram if needed.
