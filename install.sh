#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf "\033[1;34m[info]\033[0m  %s\n" "$1"; }
ok()    { printf "\033[1;32m[ok]\033[0m    %s\n" "$1"; }
warn()  { printf "\033[1;33m[warn]\033[0m  %s\n" "$1"; }

link_it() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    warn "$dst exists — backing up to ${dst}.bak"
    mv "$dst" "${dst}.bak"
  fi
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  ok "$dst → $src"
}

# ── Neovim (prebuilt tarball, no sudo/FUSE required) ────────────────────────

install_nvim() {
  local bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir"

  if command -v nvim &>/dev/null; then
    ok "nvim already installed: $(nvim --version | head -1)"
    return
  fi

  info "Installing Neovim..."
  local arch
  arch="$(uname -m)"
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  # Use prebuilt tarball — works without FUSE, more reliable than AppImage
  local url=""
  if [ "$os" = "linux" ] && [ "$arch" = "x86_64" ]; then
    url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
  elif [ "$os" = "linux" ] && { [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; }; then
    url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-arm64.tar.gz"
  elif [ "$os" = "darwin" ] && { [ "$arch" = "arm64" ] || [ "$arch" = "x86_64" ]; }; then
    url="https://github.com/neovim/neovim/releases/latest/download/nvim-macos-${arch}.tar.gz"
  else
    warn "Unsupported platform: $os/$arch — skipping nvim install"
    return
  fi

  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/nvim.tar.gz"
  tar xzf "$tmp/nvim.tar.gz" -C "$tmp"

  # Move extracted nvim to ~/.local (merges bin/, lib/, share/)
  local extracted
  extracted="$(ls -d "$tmp"/nvim-*/ 2>/dev/null | head -1)"
  if [ -z "$extracted" ]; then
    warn "Failed to extract nvim — skipping"
    rm -rf "$tmp"
    return
  fi

  cp -r "$extracted"/* "$HOME/.local/"
  rm -rf "$tmp"
  ok "nvim installed to $bin_dir/nvim"
}

# ── OpenCode ─────────────────────────────────────────────────────────────────

install_opencode() {
  if command -v opencode &>/dev/null; then
    ok "opencode already installed: $(opencode --version 2>/dev/null || echo 'unknown version')"
    return
  fi

  info "Installing OpenCode..."
  curl -fsSL https://opencode.ai/install | bash
  ok "opencode installed"
}

# ── PATH setup ───────────────────────────────────────────────────────────────

ensure_path() {
  local bin_dir="$HOME/.local/bin"
  local shell_rc

  if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
    shell_rc="$HOME/.zshrc"
  else
    shell_rc="$HOME/.bashrc"
  fi

  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$bin_dir"; then
    if ! grep -q '.local/bin' "$shell_rc" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_rc"
      ok "Added ~/.local/bin to PATH in $shell_rc"
    fi
    export PATH="$bin_dir:$PATH"
  else
    ok "~/.local/bin already on PATH"
  fi
}

# ── Shell config (prompt, aliases, etc.) ─────────────────────────────────────

setup_shell() {
  local shell_rc
  if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
    shell_rc="$HOME/.zshrc"
  else
    shell_rc="$HOME/.bashrc"
  fi

  local source_line="[ -f \"$DOTFILES_DIR/bash/bashrc\" ] && source \"$DOTFILES_DIR/bash/bashrc\""
  if ! grep -qF "dotfiles/bash/bashrc" "$shell_rc" 2>/dev/null; then
    echo "$source_line" >> "$shell_rc"
    ok "Added dotfiles bashrc source to $shell_rc"
  else
    ok "dotfiles bashrc already sourced in $shell_rc"
  fi
}

# ── Symlinks ─────────────────────────────────────────────────────────────────

setup_symlinks() {
  info "Linking configs..."
  link_it "$DOTFILES_DIR/nvim"            "$HOME/.config/nvim"
  link_it "$DOTFILES_DIR/opencode/skills" "$HOME/.opencode/skills"

  # Ghostty config only matters on machines running Ghostty (not headless servers)
  if [ -n "${DISPLAY:-}" ] || [ "$(uname -s)" = "Darwin" ]; then
    link_it "$DOTFILES_DIR/ghostty" "$HOME/.config/ghostty"
  else
    info "Headless server detected — skipping ghostty symlink"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  info "dotfiles dir: $DOTFILES_DIR"
  echo

  ensure_path
  install_nvim
  install_opencode
  setup_shell
  setup_symlinks

  echo
  ok "All done! Restart your shell or run: source ~/.bashrc"
}

main "$@"
