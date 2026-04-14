## Why

OpenCode agents running on remote Linux servers have no way to interact with a browser. Agents building frontend features (Wasp apps) cannot visually verify their work, inspect the DOM, check console errors, or take screenshots. The Chrome DevTools MCP server solves this with headless Chrome, but integrating it requires: installing Chrome without sudo, resolving platform differences (Linux Puppeteer cache vs Mac system Chrome), and ensuring multi-agent isolation so each worktree gets its own browser instance.

## What Changes

- Add a `chrome-devtools-mcp` wrapper script that resolves the Chrome binary at runtime (Puppeteer cache on Linux, system Chrome on Mac) and launches the MCP server with `--slim --headless --isolated` flags
- Add an `install_chrome_for_mcp()` function to `install.sh` that downloads Chrome via Puppeteer into userspace (`~/.cache/puppeteer/`) -- no sudo required
- Add MCP server configuration to `opencode/opencode.json` so all OpenCode sessions automatically have browser access
- Wrapper script installed to `~/.local/bin/chrome-devtools-mcp` (same pattern as existing wrappers)

## Capabilities

### New Capabilities
- `browser-mcp-integration`: Chrome DevTools MCP server setup -- wrapper script, Chrome installation, OpenCode MCP config, and multi-platform support (Linux headless + Mac system Chrome)

### Modified Capabilities
- `install-setup`: Adding Chrome/Puppeteer installation and wrapper script creation to the install pipeline

## Impact

- `install.sh`: New `install_chrome_for_mcp()` function and wrapper creation in the main flow
- `opencode/opencode.json`: New `mcp` configuration block added
- `~/.local/bin/chrome-devtools-mcp`: New wrapper script (created by install.sh)
- `~/.cache/puppeteer/`: Chrome binary downloaded here on Linux (userspace, no sudo)
- Dependencies: `chrome-devtools-mcp` npm package (fetched at runtime via `bunx`), Puppeteer (for Chrome download during install)
- Resource usage: each agent session spawns an isolated headless Chrome instance (~200-400MB RAM)
