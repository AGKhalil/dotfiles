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

# ── Neovim (AppImage, no sudo required) ─────────────────────────────────────

install_nvim() {
  local bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir"

  if command -v nvim &>/dev/null; then
    ok "nvim already installed: $(nvim --version | head -1)"
    return
  fi

  info "Installing Neovim AppImage..."
  local arch
  arch="$(uname -m)"
  local url="https://github.com/neovim/neovim/releases/latest/download/nvim.appimage"
  if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
    url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-arm64.appimage"
  fi

  curl -fsSL "$url" -o "$bin_dir/nvim"
  chmod +x "$bin_dir/nvim"
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

# ── Symlinks ─────────────────────────────────────────────────────────────────

setup_symlinks() {
  info "Linking configs..."
  link_it "$DOTFILES_DIR/nvim"         "$HOME/.config/nvim"
  link_it "$DOTFILES_DIR/ghostty"      "$HOME/.config/ghostty"
  link_it "$DOTFILES_DIR/opencode/skills" "$HOME/.opencode/skills"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  info "dotfiles dir: $DOTFILES_DIR"
  echo

  ensure_path
  install_nvim
  install_opencode
  setup_symlinks

  echo
  ok "All done! Restart your shell or run: source ~/.bashrc"
}

main "$@"
