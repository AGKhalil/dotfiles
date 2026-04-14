## 1. Wrapper Script

- [x] 1.1 Create `chrome-devtools-mcp` wrapper script in `opencode/` dotfiles directory (resolves Chrome path from Puppeteer cache on Linux, falls back to system Chrome on Mac, errors if no Chrome found, execs bunx with --slim --headless --isolated --no-usage-statistics --executable-path)
- [x] 1.2 Add `mcp` block to `opencode/opencode.json` with `chrome-devtools` entry using command `["chrome-devtools-mcp"]`

## 2. Install Script

- [x] 2.1 Add `install_chrome_for_mcp()` function to `install.sh` -- downloads Chrome via `bunx puppeteer browsers install chrome@stable` on Linux, skips on Mac, idempotent (checks Puppeteer cache first)
- [x] 2.2 Add `setup_chrome_devtools_mcp()` function to `install.sh` -- writes wrapper script to `~/.local/bin/chrome-devtools-mcp`, makes it executable
- [x] 2.3 Add `validate_chrome_libs()` helper that checks required shared libraries on Linux and warns if any are missing
- [x] 2.4 Wire new functions into `main()` flow in `install.sh` (after `install_bun`, before `setup_opencode_symlinks`)

## 3. Testing on Linux Server (proteinea-gpu-0)

- [ ] 3.1 Snapshot OpenCode state dirs -- `find ~/.local/share/opencode-* ~/.config/opencode/ -type f | sort | xargs md5sum` to capture state before changes
- [ ] 3.2 Run `install_chrome_for_mcp` and `setup_chrome_devtools_mcp` -- verify Chrome downloaded and wrapper created at `~/.local/bin/chrome-devtools-mcp`
- [ ] 3.3 Run `install_chrome_for_mcp` again -- verify idempotent (outputs "already installed", no re-download)
- [ ] 3.4 Re-run the same md5sum snapshot -- diff against 3.1 to verify OpenCode state dirs unchanged
- [ ] 3.5 Protocol-level MCP test (no LLM needed): write a node script that spawns the wrapper, sends JSON-RPC over stdin (initialize → notifications/initialized → tools/list → tools/call navigate → tools/call screenshot → tools/call evaluate), and asserts: (a) init succeeds, (b) tools/list returns exactly [navigate, evaluate, screenshot], (c) navigate returns success text, (d) screenshot returns image data, (e) evaluate returns expected string
- [ ] 3.6 OpenCode integration test: run `opencode mcp list` and verify `chrome-devtools` appears with status "connected" or "configured"
- [ ] 3.7 Full agent test: run `opencode run "Use the chrome-devtools navigate tool to go to data:text/html,<h1>test</h1> then take a screenshot"` and verify the session completes with tool calls in output
- [ ] 3.8 Run `validate_chrome_libs` -- verify passes with no warnings

## 4. Testing on Mac (local)

- [x] 4.1 Protocol-level MCP test: same node script as 3.5 but on Mac -- verify wrapper finds system Chrome and all 3 tools work
- [ ] 4.2 OpenCode integration test: `opencode mcp list` shows `chrome-devtools` configured
- [ ] 4.3 Full agent test: same `opencode run` prompt as 3.7 on Mac
- [x] 4.4 Run `install_chrome_for_mcp` on Mac -- verify it skips download and reports system Chrome will be used
