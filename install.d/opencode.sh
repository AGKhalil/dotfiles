opencode_is_installed() {
  export PATH="$HOME/.opencode/bin:$PATH"
  local version
  version=$(opencode --version 2>/dev/null || true)
  [[ $version =~ (^|[[:space:]])v?2\. ]] || return 1
  printf '%s' "${version##*v}"
}

opencode_install() {
  export PATH="$HOME/.opencode/bin:$PATH"
  curl -fsSL https://opencode.ai/v2/install | bash
}

opencode_uninstall() {
  export PATH="$HOME/.opencode/bin:$PATH"
  opencode uninstall
  rm -f -- "$HOME/.opencode/bin/opencode"
}
