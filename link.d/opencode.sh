# Files are linked individually: ~/.config/opencode also holds opencode's own
# runtime state (service.json), which must not be shadowed by the repo.
opencode_link() {
  link opencode/opencode.jsonc "$HOME/.config/opencode/opencode.jsonc"
  link opencode/cli.json "$HOME/.config/opencode/cli.json"
  link opencode/AGENTS.md "$HOME/.config/opencode/AGENTS.md"
}
