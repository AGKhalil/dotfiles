## ADDED Requirements

### Requirement: Chrome installation for MCP browser access
The install script SHALL download a Chrome binary via Puppeteer on Linux servers, without requiring sudo.

#### Scenario: First install on Linux with no cached Chrome
- **WHEN** the install script runs on Linux and no Chrome exists in `~/.cache/puppeteer/`
- **THEN** the script SHALL run `bunx puppeteer browsers install chrome@stable` to download Chrome to the Puppeteer cache

#### Scenario: Chrome already cached
- **WHEN** the install script runs and a Chrome binary already exists in `~/.cache/puppeteer/chrome/*/chrome-linux64/chrome`
- **THEN** the script SHALL skip the download and report that Chrome is already installed

#### Scenario: Install on macOS
- **WHEN** the install script runs on macOS
- **THEN** the script SHALL skip Chrome download (system Chrome is used) and report that system Chrome will be used

### Requirement: Chrome DevTools MCP wrapper creation
The install script SHALL create the `chrome-devtools-mcp` wrapper script at `~/.local/bin/chrome-devtools-mcp`.

#### Scenario: Wrapper creation
- **WHEN** the install script runs
- **THEN** the script SHALL write the wrapper script to `~/.local/bin/chrome-devtools-mcp` and make it executable

#### Scenario: Wrapper already exists
- **WHEN** the install script runs and the wrapper already exists at `~/.local/bin/chrome-devtools-mcp`
- **THEN** the script SHALL overwrite it with the current version (the wrapper is generated, not user-edited)

### Requirement: System library validation on Linux
The install script SHALL verify that required shared libraries for headless Chrome are present on Linux.

#### Scenario: All libraries present
- **WHEN** the install script runs on Linux and all required libraries are found
- **THEN** the script SHALL proceed without warnings

#### Scenario: Missing libraries detected
- **WHEN** the install script runs on Linux and one or more required libraries are missing
- **THEN** the script SHALL print a warning listing the missing libraries and note that headless Chrome may not work

### Requirement: Non-destructive installation
The Chrome and MCP installation SHALL NOT modify any existing OpenCode sessions, profiles, or data directories.

#### Scenario: Existing sessions preserved
- **WHEN** the install script runs on a machine with existing OpenCode sessions in `~/.local/share/opencode-*/`
- **THEN** those directories SHALL remain completely untouched by the install process
