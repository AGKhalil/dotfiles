## ADDED Requirements

### Requirement: Listener subscribes to ntfy events topic
The Mac listener SHALL maintain a persistent SSE connection to the configured ntfy events topic and process incoming event payloads.

#### Scenario: Event received from ntfy
- **WHEN** the listener receives a JSON event payload on the ntfy events topic
- **THEN** the listener SHALL parse the payload and display a macOS notification

### Requirement: Listener displays native macOS notifications
The listener SHALL display notifications via macOS notification center using `osascript` or `terminal-notifier`, showing the event type, server label, project/worktree name, and a brief summary.

#### Scenario: Question event received
- **WHEN** the listener receives an event of type `question`
- **THEN** the listener SHALL display a macOS notification with title "{worktree} ({server})" and body "Agent asking: {question summary}"

#### Scenario: Done event received
- **WHEN** the listener receives an event of type `done`
- **THEN** the listener SHALL display a macOS notification with title "{worktree} ({server})" and body "Agent finished"

#### Scenario: Error event received
- **WHEN** the listener receives an event of type `error`
- **THEN** the listener SHALL display a macOS notification with title "{worktree} ({server})" and body "Agent error: {error summary}"

#### Scenario: Permission event received
- **WHEN** the listener receives an event of type `permission`
- **THEN** the listener SHALL display a macOS notification with title "{worktree} ({server})" and body "Permission requested: {tool} — {action summary}"

### Requirement: Listener sends ACK after displaying notification
The listener SHALL POST an ACK to the configured ntfy ACK topic after successfully displaying a macOS notification, so the server daemon can suppress or delay Telegram escalation.

#### Scenario: Notification displayed successfully
- **WHEN** the listener has displayed a macOS notification for an event
- **THEN** the listener SHALL POST a JSON ACK payload to the ntfy ACK topic containing the event ID

### Requirement: Listener runs as a launchd service on the main machine
The listener SHALL be configured as a launchd user agent that starts on login and auto-restarts on failure.

#### Scenario: Mac boots or user logs in
- **WHEN** the user logs in to macOS
- **THEN** launchd SHALL start the listener automatically

#### Scenario: Listener crashes
- **WHEN** the listener process exits unexpectedly
- **THEN** launchd SHALL restart it automatically

### Requirement: Listener reconnects on ntfy connection loss
The listener SHALL automatically reconnect to the ntfy SSE stream if the connection drops.

#### Scenario: Network interruption
- **WHEN** the SSE connection to ntfy is lost
- **THEN** the listener SHALL retry the connection with exponential backoff (starting at 1s, max 60s)
