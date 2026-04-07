## ADDED Requirements

### Requirement: Send rich notifications with inline keyboards
The system SHALL send Telegram messages with `InlineKeyboardMarkup` appropriate to the event type.

#### Scenario: Question notification
- **WHEN** sending a Telegram notification for a `question` event with predefined options
- **THEN** the message SHALL include one inline keyboard button per option, plus a "Type custom" button, and the message text SHALL include the server label, worktree name, and full question text

#### Scenario: Permission notification
- **WHEN** sending a Telegram notification for a `permission` event
- **THEN** the message SHALL include "Allow" and "Deny" inline keyboard buttons, and the message text SHALL include the server label, worktree name, tool name, and the action being requested

#### Scenario: Error notification
- **WHEN** sending a Telegram notification for an `error` event
- **THEN** the message SHALL include "Retry" and "Abort" inline keyboard buttons, and the message text SHALL include the server label, worktree name, and error message

#### Scenario: Done notification
- **WHEN** sending a Telegram notification for a `done` event
- **THEN** the message SHALL include a "Continue" button (to send a follow-up prompt), and the message text SHALL include the server label, worktree name, and session summary

### Requirement: Callback data fits within 64-byte limit
All `callback_data` values SHALL be 64 bytes or fewer, using the first 8 characters of the session UUID as a prefix and numeric indices for options.

#### Scenario: Encoding a question response
- **WHEN** building callback_data for a question option at index 2
- **THEN** the callback_data SHALL be formatted as `r|<8-char-session-prefix>|2` and SHALL be 64 bytes or fewer

#### Scenario: Encoding a permission response
- **WHEN** building callback_data for a permission allow action
- **THEN** the callback_data SHALL be formatted as `p|<8-char-session-prefix>|a` and SHALL be 64 bytes or fewer

### Requirement: Handle free-text replies via Telegram message threading
The system SHALL support free-text responses by matching `reply_to_message_id` in incoming Telegram messages to notification messages stored in the registry.

#### Scenario: User taps "Type custom" then sends a reply
- **WHEN** the user taps "Type custom" on a question notification
- **THEN** the bot SHALL send a message saying "Reply to this message with your answer" and when the user replies, the daemon SHALL match the reply to the original event and forward the text to the OpenCode session

### Requirement: Update Telegram messages on state changes
The system SHALL call `editMessageText` to update existing notifications when their state changes.

#### Scenario: Question answered from TUI
- **WHEN** a question event's status changes to `responded`
- **THEN** the Telegram message SHALL be updated to "Answered from terminal" with the inline keyboard removed

#### Scenario: Session becomes stale
- **WHEN** a session with pending notifications is marked stale
- **THEN** the Telegram message SHALL be updated to indicate the agent is no longer running, with the inline keyboard removed

#### Scenario: Response successfully routed
- **WHEN** the daemon successfully routes a Telegram response to an OpenCode session
- **THEN** the Telegram message SHALL be updated to confirm the response was sent (e.g., "Sent: PostgreSQL. Agent continuing.")

### Requirement: Poll getUpdates for incoming responses
The daemon SHALL poll Telegram `getUpdates` with long polling (timeout 30s) in a continuous loop to receive callback queries and text messages.

#### Scenario: No updates available
- **WHEN** the `getUpdates` call returns an empty array after the timeout
- **THEN** the daemon SHALL immediately issue another `getUpdates` request

#### Scenario: Multiple updates received
- **WHEN** `getUpdates` returns multiple updates
- **THEN** the daemon SHALL process each update sequentially, call `answerCallbackQuery` for each callback, and set the offset to `last_update_id + 1` for the next poll
