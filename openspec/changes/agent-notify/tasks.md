## 1. Project scaffolding and shared modules

- [ ] 1.1 Create `agent-notify/` directory structure in dotfiles: `daemon.ts`, `listener.ts`, `config.toml`, and `src/` for shared modules
- [ ] 1.2 Create shared SQLite schema module (`src/db.ts`): define `sessions` and `events` tables, initialize database at `~/.local/share/agent-notify/registry.db`, enable WAL mode
- [ ] 1.3 Create shared types module (`src/types.ts`): event types (`done`, `error`, `question`, `permission`), event payloads, registry row types, config schema
- [ ] 1.4 Create config loader module (`src/config.ts`): read `config.toml`, resolve `env:` references from secrets file, validate required fields (bot token, chat ID, ntfy topics, role)

## 2. OpenCode plugin (event detection)

- [ ] 2.1 Create `opencode/plugins/agent-notify.ts` plugin skeleton: export plugin function receiving `{ project, client, $, directory, worktree }`, return event hooks
- [ ] 2.2 Spike: determine how to extract the OpenCode server port from the plugin context (inspect `client` object, try `client.global.health()`, fallback to `lsof`)
- [ ] 2.3 Implement session registration: on `session.created` event, insert session row in SQLite with session ID, port, project, worktree
- [ ] 2.4 Implement heartbeat: set up interval (every 30s) to update `last_seen` for all sessions owned by this plugin instance
- [ ] 2.5 Implement event classification: on `session.idle`, inspect last message parts via `client.session.messages()` to determine if idle is `done` vs `question` (askquestion tool in `waiting` state)
- [ ] 2.6 Spike: log full event payloads for `session.idle`, `session.error`, `permission.asked`, and `message.part.updated` to determine exact shapes and available fields
- [ ] 2.7 Implement `session.error` handler: write `error` event to registry with error message
- [ ] 2.8 Implement `permission.asked` handler: write `permission` event to registry with permission ID, tool name, and action details
- [ ] 2.9 Implement TUI-answered detection: when a session with a pending event resumes activity (new `message.updated` or session leaves idle), update event status to `responded`
- [ ] 2.10 Implement cleanup on shutdown: delete session rows for this instance from registry on process exit (handle SIGTERM, SIGINT)

## 3. Telegram bot client

- [ ] 3.1 Create Telegram API client module (`src/telegram.ts`): wrapper around `fetch` for `sendMessage`, `editMessageText`, `answerCallbackQuery`, `getUpdates`, `getMe`
- [ ] 3.2 Implement `sendMessage` with `InlineKeyboardMarkup`: build keyboard from event type (question options, permission allow/deny, error retry/abort, done continue)
- [ ] 3.3 Implement callback_data encoding/decoding: `r|<8-char-prefix>|<index>` for responses, `p|<8-char-prefix>|a|d` for permissions — validate 64-byte limit
- [ ] 3.4 Implement `editMessageText` helper for updating notifications on state changes (answered, stale, response confirmed)
- [ ] 3.5 Implement `getUpdates` long-polling loop with offset tracking and 30s timeout

## 4. Notification daemon

- [ ] 4.1 Create `daemon.ts` entry point: load config, initialize SQLite, start event watcher and Telegram poller
- [ ] 4.2 Implement event watcher: poll SQLite `events` table for rows with status `pending`, process each through the escalation pipeline
- [ ] 4.3 Implement ntfy sender: POST event JSON to configured ntfy events topic for Mac listener delivery
- [ ] 4.4 Implement escalation timer: after sending ntfy, start a delay timer (configurable per event type). Listen for ACK on ntfy ACK topic (SSE subscription). If ACK received, update status to `mac_acked` and suppress/extend Telegram delay. If timeout, send Telegram.
- [ ] 4.5 Implement Telegram notification sender: format message text per event type (server label, worktree, summary), attach inline keyboard, store `telegram_msg_id` in registry
- [ ] 4.6 Implement Telegram response router: on callback_query, parse callback_data, look up full session ID and port in registry, POST to `localhost:<port>/session/<id>/prompt` or permissions endpoint
- [ ] 4.7 Implement free-text reply handling: match `reply_to_message_id` to event in registry, forward text to OpenCode session
- [ ] 4.8 Implement stale session detector: periodically check `last_seen` timestamps, mark stale sessions, update Telegram messages via `editMessageText`
- [ ] 4.9 Implement Telegram message updates on registry state changes: watch for `responded` status (TUI-answered), `stale` status, and successful routing — update corresponding Telegram messages
- [ ] 4.10 Implement "Type custom" flow: on callback, send Telegram message "Reply to this message with your answer", then match the user's reply back to the event

## 5. Mac listener

- [ ] 5.1 Create `listener.ts` entry point: load config, subscribe to ntfy events topic via SSE
- [ ] 5.2 Implement macOS notification display: parse event JSON, call `osascript` to show notification with title "{worktree} ({server})" and body per event type
- [ ] 5.3 Implement ACK sender: after displaying notification, POST ACK JSON (event ID) to ntfy ACK topic
- [ ] 5.4 Implement SSE reconnection with exponential backoff: on connection loss, retry starting at 1s, max 60s

## 6. Configuration and secrets

- [ ] 6.1 Create `agent-notify/config.toml` template with all configurable fields: machine role, telegram section (env refs), ntfy section (env refs), delay section (per-event-type defaults)
- [ ] 6.2 Create secrets file structure at `~/.config/agent-notify/secrets`: store bot token, chat ID, ntfy topics — ensure path is outside git-tracked dotfiles

## 7. Install script integration

- [ ] 7.1 Add interactive Telegram setup to install script: prompt for bot token, validate via `getMe`, prompt user to send message, detect chat ID via `getUpdates`, send test message, save to secrets file
- [ ] 7.2 Add ntfy topic auto-generation: generate two random topic strings if not already configured
- [ ] 7.3 Add plugin symlink step: symlink `opencode/plugins/agent-notify.ts` to `~/.config/opencode/plugins/agent-notify.ts`
- [ ] 7.4 Create launchd plist for daemon (`com.agkhalil.agent-notify-daemon.plist`): configure `ProgramArguments` to run `bun run daemon.ts`, `KeepAlive: true`, `RunAtLoad: true`, stdout/stderr to log files
- [ ] 7.5 Create systemd user unit for daemon (`agent-notify-daemon.service`): configure `ExecStart` to run `bun run daemon.ts`, `Restart=always`, `WantedBy=default.target`
- [ ] 7.6 Create launchd plist for Mac listener (`com.agkhalil.agent-notify-listener.plist`): same pattern as daemon, installed only when role is "main"
- [ ] 7.7 Add platform-specific service installation to install script: detect OS, write appropriate service file, load/enable/start services
- [ ] 7.8 Add machine role detection to install script: read from `config.toml`, install listener only if role is "main"
- [ ] 7.9 Add post-install validation: check daemon is running, check listener is running (if main), verify Telegram bot token works, report status

## 8. Unit tests

- [ ] 8.1 Test SQLite module: create tables, insert/query sessions and events, concurrent writes from multiple connections, WAL mode, stale detection query
- [ ] 8.2 Test event classifier: given mock message parts, correctly classify idle as `done` vs `question`; given askquestion tool part in `waiting` state, extract question text and options
- [ ] 8.3 Test callback_data encoder/decoder: encode response with session prefix + option index, decode back, verify all formats fit within 64 bytes, test edge cases (long option index, boundary session IDs)
- [ ] 8.4 Test Telegram message formatter: given each event type (done, error, question, permission), verify message text includes server label, worktree, summary; verify InlineKeyboardMarkup has correct buttons per type
- [ ] 8.5 Test escalation timer: timer fires after configured delay; ACK received before delay cancels Telegram send; correct delay values per event type; multiple concurrent timers don't interfere
- [ ] 8.6 Test config loader: parse valid config.toml, resolve env: references, reject missing required fields, handle missing secrets file gracefully

## 9. Integration tests with mocks

- [ ] 9.1 Create mock Telegram server: local HTTP server that implements sendMessage (stores messages, returns IDs), editMessageText (updates stored messages), getUpdates (returns queued callbacks), answerCallbackQuery; expose helper `simulateButtonTap(msgId, callbackData)` that queues a callback_query
- [ ] 9.2 Create mock ntfy server: local HTTP server that implements POST /topic (stores messages), GET /topic/sse (SSE stream of stored messages); expose helper `getMessages(topic)` to inspect received events
- [ ] 9.3 Create mock OpenCode server: local HTTP server that implements POST /session/:id/prompt (records prompts), POST /session/:id/permissions/:permId (records permission responses); expose helper `getReceivedPrompts(sessionId)` and `getReceivedPermissions(sessionId)`
- [ ] 9.4 Test daemon event-to-notification flow: insert pending event in SQLite, start daemon with mock Telegram and mock ntfy, verify ntfy receives event JSON, wait for escalation timeout, verify mock Telegram receives sendMessage with correct keyboard
- [ ] 9.5 Test daemon response routing: insert session and event in SQLite, start daemon with mock Telegram and mock OC server, simulate button tap via mock Telegram, verify mock OC server receives correct prompt on correct port
- [ ] 9.6 Test daemon permission routing: same as 9.5 but for permission events — simulate Allow/Deny tap, verify mock OC server receives permission response (not prompt)
- [ ] 9.7 Test daemon free-text routing: insert event in SQLite, send notification via daemon, simulate "Type custom" tap then text reply via mock Telegram, verify mock OC server receives the text as a prompt
- [ ] 9.8 Test ACK suppresses Telegram: insert event, daemon sends ntfy, mock ntfy sends ACK within timeout, verify mock Telegram does NOT receive sendMessage
- [ ] 9.9 Test stale session handling: insert session with old `last_seen`, run daemon stale check, verify mock Telegram receives editMessageText marking notification as stale
- [ ] 9.10 Test TUI-answered detection: insert event with status `responded` in SQLite (simulating plugin update), verify daemon calls editMessageText on mock Telegram to update message to "Answered from terminal"
- [ ] 9.11 Test dead session routing: insert session pointing to a port with no server, simulate Telegram callback, verify daemon sends error message via mock Telegram ("Agent may have exited")

## 10. Manual smoke tests

Run these after all automated tests pass. Each test has setup steps, an action, and expected results you can visually verify.

### Prerequisites
```
Before starting, ensure:
- [ ] Telegram bot created via @BotFather, token available
- [ ] Install script has been run on your Mac (role: main)
- [ ] Install script has been run on at least one server (role: server)
- [ ] `launchctl list | grep agent-notify` shows both daemon and listener on Mac
- [ ] `systemctl --user status agent-notify-daemon` shows active on server
- [ ] You have Telegram on your phone with the bot chat open
```

### 10.1 Plugin event detection

- [ ] 10.1.1 Verify plugin loads with OpenCode
  ```
  Steps:
  1. Open a terminal in any git worktree
  2. Run: opencode
  3. Check opencode logs for "agent-notify plugin initialized"

  Expected:
  - No errors in OpenCode startup
  - Plugin log message appears
  ```

- [ ] 10.1.2 Verify session registration in SQLite
  ```
  Steps:
  1. Start opencode in a worktree
  2. Create a new session (send any prompt)
  3. In another terminal: sqlite3 ~/.local/share/agent-notify/registry.db \
       "SELECT id, port, project, worktree FROM sessions"

  Expected:
  - One row with the session ID, a port number, project name, and worktree path
  ```

- [ ] 10.1.3 Verify "done" event detection
  ```
  Steps:
  1. Start opencode, send a simple prompt like "What is 2+2?"
  2. Wait for the agent to finish responding
  3. Check: sqlite3 ~/.local/share/agent-notify/registry.db \
       "SELECT type, status, payload FROM events ORDER BY created_at DESC LIMIT 1"

  Expected:
  - Row with type="done", status="pending"
  ```

- [ ] 10.1.4 Verify "error" event detection
  ```
  Steps:
  1. Start opencode, trigger a session error (e.g., model API error by
     setting an invalid API key temporarily, or provoke a build failure
     that the agent can't recover from)
  2. Check: sqlite3 ~/.local/share/agent-notify/registry.db \
       "SELECT type, status, payload FROM events WHERE type='error' \
        ORDER BY created_at DESC LIMIT 1"

  Expected:
  - Row with type="error", status="pending", payload contains error description
  ```

- [ ] 10.1.5 Verify "permission" event detection
  ```
  Steps:
  1. Set permission config: "permission": { "bash": "ask" } in opencode.json
  2. Start opencode, send a prompt that will trigger bash execution
     (e.g., "list files in this directory")
  3. Don't approve the permission in the TUI
  4. Check: sqlite3 ~/.local/share/agent-notify/registry.db \
       "SELECT type, status, payload FROM events WHERE type='permission' \
        ORDER BY created_at DESC LIMIT 1"

  Expected:
  - Row with type="permission", status="pending", payload contains tool name and command
  ```

- [ ] 10.1.6 Verify session cleanup on exit
  ```
  Steps:
  1. Start opencode, note the session ID from SQLite
  2. Exit opencode (ctrl+c or /exit)
  3. Check: sqlite3 ~/.local/share/agent-notify/registry.db \
       "SELECT count(*) FROM sessions WHERE id='<session-id>'"

  Expected:
  - Count is 0 (session row was removed)
  ```

### 10.2 Mac notification (main machine)

- [ ] 10.2.1 Verify macOS notification on "done" event
  ```
  Steps:
  1. Ensure Mac listener is running: launchctl list | grep agent-notify-listener
  2. On any machine (Mac or server), start opencode, send a simple prompt,
     wait for agent to finish

  Expected:
  - macOS notification appears in Notification Center
  - Title: "{worktree} ({server-label})"
  - Body: "Agent finished"
  - Appears within 2-3 seconds of agent completing
  ```

- [ ] 10.2.2 Verify macOS notification on "question" event
  ```
  Steps:
  1. Start opencode with an agent that uses askquestion tool
  2. Send a prompt that triggers askquestion
     (this depends on your agent config — use an agent with the
      askquestion tool enabled)

  Expected:
  - macOS notification with body: "Agent asking: {question text}"
  ```

- [ ] 10.2.3 Verify macOS notification from a REMOTE server
  ```
  Steps:
  1. SSH into a server
  2. Start opencode in a worktree, send a prompt, wait for completion

  Expected:
  - macOS notification appears on your Mac (not on the server)
  - Title includes the server label
  ```

### 10.3 Telegram escalation

- [ ] 10.3.1 Verify Telegram notification after Mac ACK timeout
  ```
  Steps:
  1. Stop the Mac listener: launchctl unload ~/Library/LaunchAgents/com.agkhalil.agent-notify-listener.plist
  2. On any machine, trigger a "done" event (start opencode, complete a prompt)
  3. Wait for the configured delay (default 120s for "done")
  4. Check Telegram on your phone

  Expected:
  - Telegram message appears after the delay
  - Message includes server label, worktree name, and "Agent finished"
  - "Continue" button visible
  - Restart listener after test: launchctl load ~/Library/LaunchAgents/...
  ```

- [ ] 10.3.2 Verify Mac ACK suppresses Telegram
  ```
  Steps:
  1. Ensure Mac listener IS running
  2. Trigger a "done" event
  3. Verify macOS notification appears
  4. Wait for longer than the configured delay

  Expected:
  - macOS notification appears immediately
  - NO Telegram message arrives (ACK suppressed it)
  ```

- [ ] 10.3.3 Verify "question" Telegram notification has option buttons
  ```
  Steps:
  1. Stop Mac listener (so Telegram escalation fires)
  2. Trigger an askquestion event (agent asks a question with options)
  3. Wait for question delay (default 30s)

  Expected:
  - Telegram message shows the question text
  - Inline keyboard with one button per option
  - "Type custom" button at the end
  ```

- [ ] 10.3.4 Verify "permission" Telegram notification has Allow/Deny
  ```
  Steps:
  1. Stop Mac listener
  2. Set "bash": "ask" in opencode permissions, trigger bash tool usage
  3. Wait for permission delay (default 30s)

  Expected:
  - Telegram message shows tool name and command
  - "Allow" and "Deny" inline keyboard buttons
  ```

- [ ] 10.3.5 Verify "error" Telegram notification has Retry/Abort
  ```
  Steps:
  1. Stop Mac listener
  2. Trigger a session error
  3. Wait for error delay (default 60s)

  Expected:
  - Telegram message shows error description
  - "Retry" and "Abort" inline keyboard buttons
  ```

### 10.4 Telegram two-way response

- [ ] 10.4.1 Respond to a question via option button
  ```
  Steps:
  1. Get a "question" Telegram notification (per 10.3.3)
  2. Tap one of the option buttons (e.g., "PostgreSQL")

  Expected:
  - Button shows brief loading state then succeeds
  - Telegram message updates to: "Sent: PostgreSQL. Agent continuing."
  - Inline keyboard is removed from the message
  - OpenCode agent receives the answer and resumes work
     (verify in the TUI: switch to the agent's tmux window, see it continuing)
  ```

- [ ] 10.4.2 Respond to a question via "Type custom"
  ```
  Steps:
  1. Get a "question" Telegram notification
  2. Tap "Type custom"
  3. Bot replies: "Reply to this message with your answer"
  4. Reply to that message with: "Use PostgreSQL with pgbouncer"

  Expected:
  - Bot confirms: "Sent: Use PostgreSQL with pgbouncer. Agent continuing."
  - Agent receives the custom text and resumes
  ```

- [ ] 10.4.3 Allow a permission via Telegram
  ```
  Steps:
  1. Get a "permission" Telegram notification (per 10.3.4)
  2. Tap "Allow"

  Expected:
  - Telegram message updates to confirm permission was granted
  - Agent continues executing the tool in the TUI
  ```

- [ ] 10.4.4 Deny a permission via Telegram
  ```
  Steps:
  1. Get a "permission" Telegram notification
  2. Tap "Deny"

  Expected:
  - Telegram message updates to confirm permission was denied
  - Agent acknowledges the denial in the TUI
  ```

- [ ] 10.4.5 Respond to "done" via Continue button
  ```
  Steps:
  1. Get a "done" Telegram notification
  2. Tap "Continue"
  3. Bot replies: "Reply to this message with your follow-up prompt"
  4. Reply with: "Now add tests for the feature"

  Expected:
  - Agent receives the prompt and starts working on tests
  ```

### 10.5 State synchronization

- [ ] 10.5.1 Answer from TUI updates Telegram message
  ```
  Steps:
  1. Stop Mac listener so Telegram fires
  2. Trigger a "question" event, wait for Telegram notification
  3. INSTEAD of tapping Telegram, switch to the agent's tmux window
     and answer the question directly in the TUI
  4. Check the Telegram message on your phone

  Expected:
  - Telegram message updates to: "Answered from terminal"
  - Inline keyboard is removed
  ```

- [ ] 10.5.2 Stale session updates Telegram message
  ```
  Steps:
  1. Stop Mac listener so Telegram fires
  2. Start opencode, trigger an event, get a Telegram notification
  3. Kill the opencode process: kill -9 <pid>
     (use kill -9 so the cleanup hook does NOT fire)
  4. Wait for stale detection timeout (60s)
  5. Check the Telegram message

  Expected:
  - Telegram message updates to indicate agent is no longer running
  - Inline keyboard is removed
  ```

- [ ] 10.5.3 Route to dead session shows error in Telegram
  ```
  Steps:
  1. Same as 10.5.2 — kill opencode with kill -9
  2. Before stale detection fires, quickly tap a button on the
     Telegram notification

  Expected:
  - Telegram sends a new message: "Could not reach agent — it may have exited"
  ```

### 10.6 Install script

- [ ] 10.6.1 Fresh install on Mac (main machine)
  ```
  Steps:
  1. Remove existing config: rm -rf ~/.config/agent-notify
  2. Set role="main" in agent-notify/config.toml
  3. Run install script

  Expected:
  - Interactive Telegram setup prompts for bot token
  - Bot token validated ("Bot @name found")
  - Prompts to send message, detects chat ID
  - Test message arrives on Telegram
  - ntfy topics auto-generated
  - Plugin symlinked to ~/.config/opencode/plugins/
  - launchctl list shows both daemon and listener
  - Post-install validation passes (all checks green)
  ```

- [ ] 10.6.2 Fresh install on Linux server
  ```
  Steps:
  1. SSH into a Linux server
  2. Remove existing config: rm -rf ~/.config/agent-notify
  3. Set role="server" in agent-notify/config.toml
  4. Run install script

  Expected:
  - Same Telegram setup as Mac
  - Plugin symlinked
  - systemctl --user status agent-notify-daemon shows active
  - NO listener installed
  - Post-install validation passes
  ```

- [ ] 10.6.3 Re-run install (idempotent)
  ```
  Steps:
  1. Run install script again on a machine already set up

  Expected:
  - Skips Telegram setup ("Already configured")
  - Skips ntfy setup ("Topics already configured")
  - Re-symlinks plugin (no error if already exists)
  - Restarts services
  - Validation passes
  ```

### 10.7 Service resilience

- [ ] 10.7.1 Daemon auto-restarts after crash (macOS)
  ```
  Steps:
  1. Find daemon PID: launchctl list | grep agent-notify-daemon
  2. Kill it: kill -9 <pid>
  3. Wait 5 seconds
  4. Check: launchctl list | grep agent-notify-daemon

  Expected:
  - New PID appears (daemon was restarted by launchd)
  ```

- [ ] 10.7.2 Daemon auto-restarts after crash (Linux)
  ```
  Steps:
  1. Find PID: systemctl --user show agent-notify-daemon -p MainPID
  2. Kill it: kill -9 <pid>
  3. Wait 5 seconds
  4. Check: systemctl --user status agent-notify-daemon

  Expected:
  - Service shows active with new PID
  ```

- [ ] 10.7.3 Listener reconnects after network interruption
  ```
  Steps:
  1. Ensure listener is running on Mac
  2. Briefly disconnect from network (Wi-Fi off for 10s, then on)
  3. Wait 30 seconds for reconnection
  4. Trigger an event on any server

  Expected:
  - macOS notification still appears (listener reconnected to ntfy)
  ```

- [ ] 10.7.4 Daemon starts on boot (macOS)
  ```
  Steps:
  1. Reboot Mac
  2. After login, check: launchctl list | grep agent-notify

  Expected:
  - Both daemon and listener are running
  ```
