## ADDED Requirements

### Requirement: Plugin detects session idle events
The plugin SHALL subscribe to `session.idle` events and classify the idle reason by inspecting the last message parts of the session.

#### Scenario: Agent finishes work normally
- **WHEN** a `session.idle` event fires and the last message contains no `askquestion` tool parts in `waiting` state and no pending permissions
- **THEN** the plugin SHALL write an event of type `done` to the SQLite registry with the session ID and a summary of the session title

#### Scenario: Agent asks a question via askquestion tool
- **WHEN** a `session.idle` event fires and the last message contains a tool part with `askquestion` in `waiting` state
- **THEN** the plugin SHALL extract the question text and options from the tool part metadata and write an event of type `question` to the registry with the full question payload (text, options list)

### Requirement: Plugin detects session error events
The plugin SHALL subscribe to `session.error` events and emit a notification event with the error details.

#### Scenario: Session encounters an error
- **WHEN** a `session.error` event fires
- **THEN** the plugin SHALL write an event of type `error` to the SQLite registry with the session ID and available error message

### Requirement: Plugin detects permission requests
The plugin SHALL subscribe to `permission.asked` events and emit a notification event with the permission details.

#### Scenario: Agent requests permission for a tool execution
- **WHEN** a `permission.asked` event fires
- **THEN** the plugin SHALL write an event of type `permission` to the registry with the session ID, permission ID, tool name, and the command or action being requested

### Requirement: Plugin registers sessions in the SQLite registry
The plugin SHALL register each session with its OpenCode server port in the shared SQLite registry so the daemon can route responses back.

#### Scenario: New session is created
- **WHEN** a `session.created` event fires
- **THEN** the plugin SHALL insert a row in the `sessions` table with the session ID, server port, project name, and worktree path

#### Scenario: Plugin heartbeat
- **WHEN** the plugin is running
- **THEN** the plugin SHALL update the `last_seen` timestamp for all its sessions in the registry at a regular interval (no less than every 30 seconds)

### Requirement: Plugin cleans up on shutdown
The plugin SHALL remove its session entries from the registry when the OpenCode instance exits.

#### Scenario: OpenCode instance exits normally
- **WHEN** the OpenCode process shuts down
- **THEN** the plugin SHALL delete its session rows from the `sessions` table

### Requirement: Plugin detects session answered from TUI
The plugin SHALL detect when a session that had a pending notification event resumes activity (answered from the TUI directly) and update the event status.

#### Scenario: User answers question from TUI
- **WHEN** a session that has a pending `question` event in the registry transitions out of idle (new message activity detected)
- **THEN** the plugin SHALL update the event status to `responded` in the registry
