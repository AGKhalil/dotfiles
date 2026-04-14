## Context

OpenCode agents run on remote Linux servers (e.g., proteinea-gpu-0, Ubuntu 22.04) without sudo access. Each agent works in an isolated git worktree managed by Worktrunk, which generates deterministic per-branch ports via `hash_port` (written to `.env`). Agents need browser access to verify frontend work, inspect DOM/console, and take screenshots.

The Chrome DevTools MCP server (`chrome-devtools-mcp` npm package) provides this via Puppeteer, but requires resolving two platform-specific issues:
1. **Linux servers**: No system Chrome installed, no sudo to install one. Puppeteer can download Chrome to `~/.cache/puppeteer/` but the MCP server doesn't use that cache by default -- it looks for system Chrome at `/opt/google/chrome/chrome`.
2. **Mac**: System Chrome exists at a known path. No download needed.

The MCP server's `--executable-path` flag overrides the Chrome lookup, but OpenCode's JSON config doesn't support shell expansion (`~`, `$HOME`) in command args.

Current dotfiles already follow the pattern of shell wrapper scripts for platform abstraction (the `opencode` wrapper handles profile isolation and auth port patching).

## Goals / Non-Goals

**Goals:**
- Give every OpenCode session browser access via the Chrome DevTools MCP slim toolset (navigate, evaluate, screenshot)
- Work on both Linux servers (no sudo, Puppeteer-cached Chrome) and Mac (system Chrome)
- Multi-agent safe: each session gets an isolated Chrome instance via `--isolated`
- Non-destructive: installing Chrome/wrapper must not touch OpenCode sessions, profiles, or config data
- Idempotent: running install twice is safe

**Non-Goals:**
- Full 29-tool Chrome DevTools suite (slim mode's 3 tools are sufficient)
- Headed (visible) Chrome on servers -- headless only
- Beam integration -- Chrome runs locally on the same server as the agent, no tunnels needed
- Managing Chrome updates -- Puppeteer pins a compatible version at install time

## Decisions

### 1. Shell wrapper at `~/.local/bin/chrome-devtools-mcp`

**Decision**: A 6-line bash wrapper that resolves Chrome at runtime and execs the MCP server.

**Why**: OpenCode's `command` array in JSON doesn't support `~`, `$HOME`, or any shell expansion. The MCP server's `--executable-path` needs an absolute path to Chrome, which differs by platform and changes with Puppeteer version updates. A wrapper absorbs all this.

**Alternatives considered**:
- *Stable symlink* (`~/.local/share/.../chrome → puppeteer cache`): Still can't reference from JSON without `$HOME` expansion. Would need the wrapper anyway.
- *Environment variable* (`PUPPETEER_EXECUTABLE_PATH`): The MCP server doesn't read this. Only `--executable-path` works.
- *Hardcoded absolute path in JSON*: Breaks across machines with different usernames/home dirs. The dotfiles repo is shared.

### 2. Chrome installed via `bunx puppeteer browsers install chrome@stable`

**Decision**: Use Puppeteer's browser download mechanism to install Chrome into `~/.cache/puppeteer/`.

**Why**: No sudo required. Downloads a self-contained Chrome binary with bundled dependencies. Already validated on proteinea-gpu-0 -- all required system libs (libX11, libnss3, libgbm, etc.) are present on Ubuntu 22.04. Bun is already available on all target machines.

**Alternatives considered**:
- *System package (`apt install chromium-browser`)*: Requires sudo, which we don't have.
- *Manual download of Chrome .deb and extract*: More complex, same result as Puppeteer's download, less maintainable.

### 3. MCP config uses wrapper name only: `["chrome-devtools-mcp"]`

**Decision**: The `opencode.json` MCP command is simply `["chrome-devtools-mcp"]`, relying on the wrapper being on `PATH`.

**Why**: Clean, portable, no path resolution in JSON. The wrapper is at `~/.local/bin/` which is already on PATH for all OpenCode sessions (ensured by `install.sh`'s `ensure_path` function).

### 4. All flags baked into the wrapper, not the JSON config

**Decision**: `--slim`, `--headless`, `--isolated`, `--no-usage-statistics` are hardcoded in the wrapper script, not in `opencode.json` args.

**Why**: Keeps the JSON config minimal. The wrapper is the single source of truth for how Chrome DevTools MCP runs. If flags need to change, update one file. The wrapper also passes through any additional args (`"$@"`) so the JSON config can still add overrides if needed.

### 5. Linux-only Chrome download, Mac uses system Chrome

**Decision**: The `install_chrome_for_mcp()` function only downloads Chrome on Linux. On Mac, the wrapper falls back to the system Chrome path.

**Why**: Every Mac has Chrome installed. Downloading a second copy wastes ~500MB and adds complexity. The wrapper's runtime detection handles this: glob Puppeteer cache first, fall back to `/Applications/Google Chrome.app/...` on Darwin.

## Risks / Trade-offs

**[Puppeteer Chrome version drift]** → The cached Chrome version is pinned at install time. Over time it may become stale. Mitigation: re-running `install.sh` or `bunx puppeteer browsers install chrome@stable` updates it. The MCP server itself is always `@latest` via `bunx`.

**[System lib availability on other Linux distros]** → Validated on Ubuntu 22.04 where X11 libs are pre-installed. Other distros or minimal containers may lack them. Mitigation: `install.sh` can add a validation step that checks required libs and warns.

**[RAM usage with multiple agents]** → Each isolated Chrome instance uses ~200-400MB. With 4-5 concurrent agents, that's 1-2GB. Mitigation: acceptable on GPU servers with 64GB+ RAM. The `--isolated` flag ensures cleanup when the MCP server exits.

**[bunx resolution overhead]** → `bunx --bun chrome-devtools-mcp@latest` resolves from npm on first run per cache cycle. Mitigation: after first resolution, bun caches the package. Startup adds ~2-3 seconds on first use.
