claude_is_installed() {
  export PATH="$HOME/.local/bin:$PATH"
  local version label
  command -v claude >/dev/null 2>&1 || return 1
  version=$(claude --version 2>/dev/null || true)
  label=${version:-unknown}
  printf '%s' "${label%% *}"
}

claude_install() {
  curl -fsSL https://claude.ai/install.sh | bash
}

# Leaves ~/.claude settings and session history in place.
claude_uninstall() {
  rm -f -- "$HOME/.local/bin/claude"
  rm -- "$HOME/.claude.json"
}
