#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf "\033[1;34m[info]\033[0m  %s\n" "$1"; }
ok()    { printf "\033[1;32m[ok]\033[0m    %s\n" "$1"; }
warn()  { printf "\033[1;33m[warn]\033[0m  %s\n" "$1"; }
err()   { printf "\033[1;31m[err]\033[0m   %s\n" "$1"; }

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

install_opencode_binary() {
  if [ -x "$HOME/.opencode/bin/opencode" ]; then
    ok "opencode binary already installed"
    return
  fi

  info "Installing OpenCode binary..."
  curl -fsSL https://opencode.ai/install | bash
  ok "opencode binary installed"
}

# ── OpenCode profile setup ───────────────────────────────────────────────────

prompt_opencode_profile() {
  # Allow non-interactive override via OPENCODE_PROFILE env var
  if [ -n "${OPENCODE_PROFILE:-}" ]; then
    echo "$OPENCODE_PROFILE"
    return
  fi

  # All interactive output goes to stderr so command substitution doesn't eat it
  echo >&2
  info "OpenCode profile setup" >&2
  echo "  1) personal  — single personal profile" >&2
  echo "  2) work      — single work profile" >&2
  echo "  3) both      — personal (default) + work" >&2
  echo >&2
  printf "  Choose [1/2/3]: " >&2
  read -r choice

  case "$choice" in
    1) echo "personal" ;;
    2) echo "work" ;;
    3) echo "both" ;;
    *)
      warn "Invalid choice '$choice' — defaulting to 'personal'" >&2
      echo "personal"
      ;;
  esac
}

create_wrapper() {
  local name="$1" profile="$2" data_dir="$3"
  local wrapper="$HOME/.local/bin/$name"

  mkdir -p "$HOME/.local/bin"
  cat > "$wrapper" <<EOF
#!/bin/bash
# $name — OpenCode $profile profile
export XDG_DATA_HOME="\${HOME}/.local/share/opencode-$profile"
exec ~/.opencode/bin/opencode "\$@"
EOF
  chmod +x "$wrapper"
  ok "Created wrapper: $wrapper (profile: $profile)"
}

setup_opencode_profiles() {
  local profile="$1"

  case "$profile" in
    personal)
      create_wrapper "opencode" "personal" "$HOME/.local/share/opencode-personal"
      # Remove work wrapper if it exists from a previous install
      if [ -f "$HOME/.local/bin/opencode-work" ]; then
        rm "$HOME/.local/bin/opencode-work"
        ok "Removed opencode-work wrapper (not selected)"
      fi
      ;;
    work)
      create_wrapper "opencode" "work" "$HOME/.local/share/opencode-work"
      # Remove work wrapper if it exists (single profile uses 'opencode' name)
      if [ -f "$HOME/.local/bin/opencode-work" ]; then
        rm "$HOME/.local/bin/opencode-work"
        ok "Removed opencode-work wrapper (single work profile uses 'opencode')"
      fi
      ;;
    both)
      create_wrapper "opencode" "personal" "$HOME/.local/share/opencode-personal"
      create_wrapper "opencode-work" "work" "$HOME/.local/share/opencode-work"
      ;;
  esac
}

# ── OpenCode symlinks ────────────────────────────────────────────────────────

setup_opencode_symlinks() {
  info "Linking OpenCode configs..."

  # ~/.opencode/skills → dotfiles
  link_it "$DOTFILES_DIR/opencode/skills" "$HOME/.opencode/skills"

  # ~/.config/opencode/ symlinks → dotfiles
  link_it "$DOTFILES_DIR/opencode/tui.json"      "$HOME/.config/opencode/tui.json"
  link_it "$DOTFILES_DIR/opencode/agents"         "$HOME/.config/opencode/agents"
  link_it "$DOTFILES_DIR/opencode/commands"        "$HOME/.config/opencode/commands"
  link_it "$DOTFILES_DIR/opencode/opencode.json"  "$HOME/.config/opencode/opencode.json"
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

# ── General symlinks ─────────────────────────────────────────────────────────

setup_symlinks() {
  info "Linking configs..."
  link_it "$DOTFILES_DIR/nvim" "$HOME/.config/nvim"

  # Ghostty config only matters on machines running Ghostty (not headless servers)
  if [ -n "${DISPLAY:-}" ] || [ "$(uname -s)" = "Darwin" ]; then
    link_it "$DOTFILES_DIR/ghostty" "$HOME/.config/ghostty"
  else
    info "Headless server detected — skipping ghostty symlink"
  fi
}

# ── Uninstall ────────────────────────────────────────────────────────────────

uninstall() {
  echo
  warn "This will remove all dotfile-managed installations from this machine."
  echo
  echo "  The following will be REMOVED:"
  echo "    - OpenCode binary           (~/.opencode/)"
  echo "    - OpenCode config           (~/.config/opencode/)"
  echo "    - OpenCode plugin cache     (~/.cache/opencode/)"
  echo "    - OpenCode wrapper scripts  (~/.local/bin/opencode, opencode-work)"
  echo "    - OpenCode data dirs        (~/.local/share/opencode-*)"
  echo "    - Neovim config symlink     (~/.config/nvim)"
  echo "    - Ghostty config symlink    (~/.config/ghostty)"
  echo
  echo "  The following will be KEPT:"
  echo "    - Dotfiles repo             ($DOTFILES_DIR)"
  echo "    - Shell rc files            (~/.bashrc, ~/.zshrc, etc.)"
  echo "    - Neovim binary             (~/.local/bin/nvim)"
  echo
  printf "  Type 'yes' to confirm: "
  read -r confirm

  if [ "$confirm" != "yes" ]; then
    info "Uninstall cancelled."
    return
  fi

  echo

  # OpenCode binary + skills symlink
  if [ -d "$HOME/.opencode" ]; then
    rm -rf "$HOME/.opencode"
    ok "Removed ~/.opencode/"
  fi

  # OpenCode config (symlinks + generated node_modules)
  if [ -d "$HOME/.config/opencode" ]; then
    rm -rf "$HOME/.config/opencode"
    ok "Removed ~/.config/opencode/"
  fi

  # OpenCode plugin cache
  if [ -d "$HOME/.cache/opencode" ]; then
    rm -rf "$HOME/.cache/opencode"
    ok "Removed ~/.cache/opencode/"
  fi

  # Wrapper scripts
  for wrapper in opencode opencode-work; do
    if [ -f "$HOME/.local/bin/$wrapper" ]; then
      rm "$HOME/.local/bin/$wrapper"
      ok "Removed ~/.local/bin/$wrapper"
    fi
  done

  # Data directories (sessions, auth, DBs)
  for dir in "$HOME"/.local/share/opencode-*; do
    if [ -d "$dir" ]; then
      rm -rf "$dir"
      ok "Removed $dir"
    fi
  done

  # Legacy dirs (in case they exist)
  if [ -d "$HOME/.local/share/opencode" ]; then
    rm -rf "$HOME/.local/share/opencode"
    ok "Removed legacy ~/.local/share/opencode/"
  fi
  if [ -d "$HOME/.config/opencode-spaces" ]; then
    rm -rf "$HOME/.config/opencode-spaces"
    ok "Removed legacy ~/.config/opencode-spaces/"
  fi

  # Neovim config symlink (keep the binary)
  if [ -L "$HOME/.config/nvim" ]; then
    rm "$HOME/.config/nvim"
    ok "Removed ~/.config/nvim symlink"
  fi

  # Ghostty config symlink
  if [ -L "$HOME/.config/ghostty" ]; then
    rm "$HOME/.config/ghostty"
    ok "Removed ~/.config/ghostty symlink"
  fi

  echo
  ok "Uninstall complete. Dotfiles repo preserved at $DOTFILES_DIR"
  info "You may want to remove the source line from your shell rc manually."
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 [--uninstall]"
  echo
  echo "  install.sh            Install dotfiles, tools, and OpenCode profiles"
  echo "  install.sh --uninstall  Remove all dotfile-managed installations"
  echo
  echo "Environment variables:"
  echo "  OPENCODE_PROFILE=personal|work|both  Skip interactive prompt"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
  fi

  if [ "${1:-}" = "--uninstall" ]; then
    uninstall
    exit 0
  fi

  info "dotfiles dir: $DOTFILES_DIR"
  echo

  ensure_path
  install_nvim
  install_opencode_binary
  setup_shell
  setup_symlinks

  # OpenCode profile selection + config
  local profile
  profile="$(prompt_opencode_profile)"
  info "Setting up OpenCode with profile: $profile"
  setup_opencode_profiles "$profile"
  setup_opencode_symlinks

  echo
  ok "All done! Restart your shell or run: source ~/.bashrc"
}

main "$@"
