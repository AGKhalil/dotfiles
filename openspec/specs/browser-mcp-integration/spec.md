## ADDED Requirements

### Requirement: Chrome DevTools MCP wrapper script
The system SHALL provide a wrapper script at `~/.local/bin/chrome-devtools-mcp` that resolves the Chrome binary path at runtime and launches the MCP server with the correct flags.

#### Scenario: Wrapper invoked on Linux with Puppeteer-cached Chrome
- **WHEN** the wrapper runs on Linux and a Chrome binary exists in `~/.cache/puppeteer/chrome/*/chrome-linux64/chrome`
- **THEN** the wrapper SHALL launch `bunx --bun chrome-devtools-mcp@latest` with `--slim --headless --isolated --no-usage-statistics --executable-path <resolved-path>` and pass through any additional arguments

#### Scenario: Wrapper invoked on Mac with system Chrome
- **WHEN** the wrapper runs on macOS and no Puppeteer-cached Chrome exists
- **THEN** the wrapper SHALL launch `bunx --bun chrome-devtools-mcp@latest` with `--slim --headless --isolated --no-usage-statistics` without `--executable-path` (letting the MCP server find system Chrome)

#### Scenario: Wrapper invoked with no Chrome available
- **WHEN** the wrapper runs and no Chrome binary is found (no Puppeteer cache on Linux, no system Chrome on Mac)
- **THEN** the wrapper SHALL exit with a non-zero status and print an error message indicating Chrome is not installed

### Requirement: OpenCode MCP server configuration
The system SHALL configure the Chrome DevTools MCP server in `opencode.json` so it is available to all OpenCode sessions.

#### Scenario: MCP config references wrapper
- **WHEN** OpenCode starts a session
- **THEN** the `opencode.json` SHALL contain an `mcp` block with a `chrome-devtools` entry whose command is `["chrome-devtools-mcp"]`

### Requirement: Multi-agent browser isolation
Each OpenCode agent session SHALL get its own isolated Chrome instance that does not share state with other sessions.

#### Scenario: Two agents running concurrently in different worktrees
- **WHEN** two OpenCode agents are running on the same server in different worktrees
- **THEN** each agent's Chrome DevTools MCP server SHALL launch a separate headless Chrome instance with its own temporary user-data-dir (via `--isolated`)

#### Scenario: Chrome cleanup on session end
- **WHEN** an OpenCode session ends and the MCP server process exits
- **THEN** the isolated Chrome instance and its temporary user-data-dir SHALL be cleaned up automatically

### Requirement: Slim toolset only
The MCP server SHALL expose only the slim toolset to minimize token overhead.

#### Scenario: Available tools in a session
- **WHEN** an OpenCode agent queries available MCP tools
- **THEN** the chrome-devtools server SHALL expose exactly three tools: `navigate`, `evaluate`, and `screenshot`
