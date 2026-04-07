## ADDED Requirements

### Requirement: Daemon watches the SQLite registry for new events
The daemon SHALL poll the SQLite registry for new events with status `pending` and process them through the notification escalation pipeline.

#### Scenario: New event appears in registry
- **WHEN** a new event row with status `pending` is detected in the `events` table
- **THEN** the daemon SHALL begin the notification escalation flow for that event

### Requirement: Daemon sends events to ntfy for Mac notification
The daemon SHALL POST event details to the configured ntfy events topic so the Mac listener can display a macOS notification.

#### Scenario: Event is pending and Mac listener may be available
- **WHEN** a new pending event is detected
- **THEN** the daemon SHALL POST a JSON payload to the ntfy events topic containing the event ID, type, session metadata (project, worktree, server label), and a human-readable summary

### Requirement: Daemon manages escalation timers
The daemon SHALL start a configurable delay timer after sending the ntfy event. If the Mac listener ACKs within the timeout, Telegram escalation SHALL be suppressed or further delayed. If no ACK is received, the daemon SHALL send the Telegram notification.

#### Scenario: Mac listener ACKs within timeout
- **WHEN** the daemon receives an ACK for an event on the ntfy ACK topic before the delay timer expires
- **THEN** the daemon SHALL update the event status to `mac_acked` and either suppress the Telegram notification entirely or extend the delay significantly (configurable)

#### Scenario: No ACK received within timeout
- **WHEN** the delay timer expires without an ACK
- **THEN** the daemon SHALL send the Telegram notification and update the event status to `tg_sent`

### Requirement: Daemon routes Telegram responses to OpenCode sessions
The daemon SHALL poll Telegram `getUpdates`, parse callback queries and text replies, and route them to the correct OpenCode session via localhost HTTP.

#### Scenario: User taps an inline keyboard button
- **WHEN** the daemon receives a `callback_query` from Telegram with response data
- **THEN** the daemon SHALL parse the callback data to extract the session ID prefix and selected option, look up the full session ID and port in the registry, and POST the response to `localhost:<port>/session/<id>/prompt` (or the permissions endpoint for permission responses)

#### Scenario: User sends a free-text reply
- **WHEN** the daemon receives a text message that is a reply to a notification message
- **THEN** the daemon SHALL match the `reply_to_message_id` to an event in the registry, look up the session, and POST the text as a prompt to the OpenCode session

#### Scenario: Target OpenCode instance is unreachable
- **WHEN** the daemon attempts to route a response but the localhost HTTP request fails
- **THEN** the daemon SHALL send a Telegram message informing the user that the agent may have exited, and update the event status to `stale`

### Requirement: Daemon detects and cleans up stale sessions
The daemon SHALL periodically check the `last_seen` timestamp of registered sessions and mark sessions as stale if they exceed a threshold.

#### Scenario: Session heartbeat expires
- **WHEN** a session's `last_seen` timestamp is older than 60 seconds
- **THEN** the daemon SHALL mark the session as stale, and update any pending Telegram notifications for that session via `editMessageText` to indicate the agent is no longer running

### Requirement: Daemon updates Telegram messages on session state change
The daemon SHALL update existing Telegram notification messages when the underlying event state changes (answered from TUI, session became stale).

#### Scenario: Event answered from TUI
- **WHEN** the daemon detects an event status changed to `responded` in the registry
- **THEN** the daemon SHALL call Telegram `editMessageText` to update the notification with "Answered from terminal" and remove the inline keyboard

### Requirement: Daemon runs as a system service
The daemon SHALL be configured to run as a launchd user agent (macOS) or systemd user unit (Linux) with auto-restart on failure.

#### Scenario: Daemon crashes
- **WHEN** the daemon process exits unexpectedly
- **THEN** the service manager SHALL restart it automatically

#### Scenario: System boots
- **WHEN** the system starts (or user logs in on macOS)
- **THEN** the service manager SHALL start the daemon automatically
