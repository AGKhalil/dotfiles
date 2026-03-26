## ADDED Requirements

### Requirement: Interactive Telegram bot setup on first run
The install script SHALL detect when no Telegram credentials are configured and run an interactive setup flow.

#### Scenario: First-time install with no existing config
- **WHEN** the install script runs and no Telegram bot token is found in the secrets file
- **THEN** the script SHALL prompt the user to paste their bot token, validate it via `getMe`, prompt the user to send a message to the bot, detect the chat ID via `getUpdates`, send a test message, and save both values to the secrets file

#### Scenario: Bot token is invalid
- **WHEN** the user pastes an invalid bot token
- **THEN** the script SHALL display an error and prompt the user to try again

#### Scenario: No message detected from user
- **WHEN** the user presses Enter but no message is found via `getUpdates`
- **THEN** the script SHALL inform the user and prompt them to try again

### Requirement: Machine role configuration
The install script SHALL determine whether the machine is the main machine (Mac with listener) or a server (daemon only) via the config file.

#### Scenario: Config specifies main machine
- **WHEN** `config.toml` has `role = "main"`
- **THEN** the install script SHALL install the plugin, daemon, and Mac listener

#### Scenario: Config specifies server
- **WHEN** `config.toml` has `role = "server"`
- **THEN** the install script SHALL install the plugin and daemon only (no Mac listener)

### Requirement: Plugin symlink to global opencode plugins directory
The install script SHALL symlink the agent-notify plugin to the global OpenCode plugins directory.

#### Scenario: Install plugin
- **WHEN** the install script runs
- **THEN** the plugin file SHALL be symlinked to `~/.config/opencode/plugins/agent-notify.ts`

### Requirement: Platform-specific daemon service installation
The install script SHALL install the daemon as a platform-native service.

#### Scenario: macOS installation
- **WHEN** the install script runs on macOS
- **THEN** the script SHALL write a launchd plist to `~/Library/LaunchAgents/` and load it via `launchctl`

#### Scenario: Linux installation
- **WHEN** the install script runs on Linux
- **THEN** the script SHALL write a systemd user unit to `~/.config/systemd/user/` and enable/start it via `systemctl --user`

### Requirement: Mac listener service installation on main machine only
The install script SHALL install the Mac listener as a launchd service only when the machine role is "main".

#### Scenario: Main machine macOS installation
- **WHEN** the install script runs on macOS with role "main"
- **THEN** the script SHALL write a launchd plist for the listener to `~/Library/LaunchAgents/` and load it

#### Scenario: Server installation skips listener
- **WHEN** the install script runs with role "server"
- **THEN** the script SHALL NOT install the Mac listener

### Requirement: Auto-generate ntfy topics
The install script SHALL generate random ntfy topic names if none are configured, to avoid topic collisions between users.

#### Scenario: No ntfy topics configured
- **WHEN** the install script runs and no ntfy topics are found in the config
- **THEN** the script SHALL generate two random topic strings (events and ACK) and save them to the config

### Requirement: Secrets stored outside git-tracked dotfiles
Sensitive values (Telegram bot token, chat ID) SHALL be stored in a file that is NOT tracked by git.

#### Scenario: Secrets file location
- **WHEN** the install script saves Telegram credentials
- **THEN** the credentials SHALL be written to `~/.config/agent-notify/secrets` (or equivalent) which is NOT inside the dotfiles git repository

### Requirement: Install script validates services after setup
The install script SHALL verify that all installed services are running correctly.

#### Scenario: Post-install validation
- **WHEN** the install script finishes installing services
- **THEN** the script SHALL check that the daemon is running, check that the listener is running (if main machine), verify the Telegram bot token works, and report the status of each component
