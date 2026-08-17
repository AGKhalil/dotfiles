#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf "\033[1;34m[info]\033[0m  %s\n" "$1"; }
ok()    { printf "\033[1;32m[ok]\033[0m    %s\n" "$1"; }
warn()  { printf "\033[1;33m[warn]\033[0m  %s\n" "$1"; }
err()   { printf "\033[1;31m[err]\033[0m   %s\n" "$1"; }

CYAN="\033[1;36m"
RESET="\033[0m"

# Interactive arrow-key selector (adapted from beam).
# Reads options from stdin, renders a navigable list to stderr,
# prints the 0-based index of the selected item to stdout.
# Returns 1 on cancel (Esc / q).
arrow_select() {
  declare -a items
  while IFS= read -r line; do
    items+=("$line")
  done

  local count=${#items[@]}
  [[ $count -eq 0 ]] && return 1

  local cur=0

  printf "\033[?25l" >&2
  local saved_tty
  saved_tty=$(stty -g </dev/tty 2>/dev/null)
  stty -echo -icanon min 1 </dev/tty 2>/dev/null

  _arrow_draw() {
    for i in "${!items[@]}"; do
      if [[ $i -eq $cur ]]; then
        printf "  ${CYAN}>${RESET} %b\n" "${items[$i]}" >&2
      else
        printf "    %b\n" "${items[$i]}" >&2
      fi
    done
  }

  _arrow_clear() {
    for (( i=0; i<count; i++ )); do
      printf "\033[A\033[2K" >&2
    done
  }

  echo "" >&2
  _arrow_draw

  while true; do
    local key
    key=$(dd bs=1 count=1 2>/dev/null </dev/tty)

    case "$key" in
      $'\x1b')
        local seq1 seq2
        seq1=$(dd bs=1 count=1 2>/dev/null </dev/tty)
        seq2=$(dd bs=1 count=1 2>/dev/null </dev/tty)
        if [[ "$seq1" == "[" ]]; then
          case "$seq2" in
            A) [[ $cur -gt 0 ]] && cur=$((cur - 1)) ;;
            B) [[ $cur -lt $((count - 1)) ]] && cur=$((cur + 1)) ;;
          esac
        else
          _arrow_clear
          stty "$saved_tty" </dev/tty 2>/dev/null
          printf "\033[?25h" >&2
          return 1
        fi
        ;;
      ""|$'\n')
        _arrow_clear
        printf "  ${CYAN}>${RESET} %b\n" "${items[$cur]}" >&2
        stty "$saved_tty" </dev/tty 2>/dev/null
        printf "\033[?25h" >&2
        echo "$cur"
        return 0
        ;;
      q|Q)
        _arrow_clear
        stty "$saved_tty" </dev/tty 2>/dev/null
        printf "\033[?25h" >&2
        return 1
        ;;
      k) [[ $cur -gt 0 ]] && cur=$((cur - 1)) ;;
      j) [[ $cur -lt $((count - 1)) ]] && cur=$((cur + 1)) ;;
    esac

    _arrow_clear
    _arrow_draw
  done
}

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

# ── Bun ──────────────────────────────────────────────────────────────────────

install_bun() {
  if command -v bun &>/dev/null; then
    ok "bun already installed: $(bun --version)"
    return
  fi

  # Also check the default install location
  if [ -x "$HOME/.bun/bin/bun" ]; then
    ok "bun already installed: $($HOME/.bun/bin/bun --version)"
    return
  fi

  info "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash
  ok "bun installed to ~/.bun/bin/bun"
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

# ── OpenSpec CLI ─────────────────────────────────────────────────────────────

install_openspec() {
  if command -v openspec &>/dev/null; then
    ok "openspec already installed: $(openspec --version 2>/dev/null)"
    return
  fi

  info "Installing openspec CLI..."

  if command -v npm &>/dev/null; then
    npm install -g @fission-ai/openspec
  elif command -v bun &>/dev/null || [ -x "$HOME/.bun/bin/bun" ]; then
    local bun_cmd="${HOME}/.bun/bin/bun"
    command -v bun &>/dev/null && bun_cmd="bun"
    $bun_cmd install -g @fission-ai/openspec

    # openspec uses #!/usr/bin/env node — symlink bun as node if node is missing
    if ! command -v node &>/dev/null; then
      local bun_bin
      bun_bin="$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")"
      ln -sf "$bun_bin" "$HOME/.local/bin/node"
      ok "Symlinked bun as node (for openspec shebang)"
    fi
  else
    warn "Neither npm nor bun found — install openspec manually: npm install -g @fission-ai/openspec"
    return
  fi

  ok "openspec installed"
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

# ── Tmux (build from source on Linux for 3.5+) ──────────────────────────────

TMUX_REQUIRED_VERSION="3.5"

install_tmux() {
  local current_version=""
  if command -v tmux &>/dev/null; then
    current_version="$(tmux -V | grep -oE '[0-9]+\.[0-9]+[a-z]?' | head -1)"
  fi

  # Compare major.minor (strip trailing letter)
  local current_num="${current_version%%[a-z]*}"
  local required_num="$TMUX_REQUIRED_VERSION"

  if [ -n "$current_num" ]; then
    local cur_major="${current_num%%.*}"
    local cur_minor="${current_num##*.}"
    local req_major="${required_num%%.*}"
    local req_minor="${required_num##*.}"

    if [ "$cur_major" -gt "$req_major" ] 2>/dev/null ||
       { [ "$cur_major" -eq "$req_major" ] && [ "$cur_minor" -ge "$req_minor" ]; } 2>/dev/null; then
      ok "tmux already installed: $current_version (>= $TMUX_REQUIRED_VERSION)"
      return
    fi
  fi

  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  if [ "$os" = "darwin" ]; then
    if command -v brew &>/dev/null; then
      info "Upgrading tmux via Homebrew..."
      brew install tmux
      ok "tmux installed: $(tmux -V)"
    else
      warn "Homebrew not found — install tmux >= $TMUX_REQUIRED_VERSION manually"
    fi
    return
  fi

  # Linux: build from source into ~/.local (no sudo required)
  info "Building tmux ${TMUX_REQUIRED_VERSION}a from source (current: ${current_version:-none})..."

  local prefix="$HOME/.local"
  local tmp
  tmp="$(mktemp -d)"

  # Build libevent from source if headers are missing
  if [ ! -f /usr/include/event2/event.h ] && [ ! -f "$prefix/include/event2/event.h" ]; then
    info "Building libevent (headers not found)..."
    local le_ver="2.1.12-stable"
    curl -fsSL "https://github.com/libevent/libevent/releases/download/release-${le_ver}/libevent-${le_ver}.tar.gz" \
      -o "$tmp/libevent.tar.gz"
    tar xzf "$tmp/libevent.tar.gz" -C "$tmp"
    ( cd "$tmp/libevent-${le_ver}" && ./configure --prefix="$prefix" --disable-shared >/dev/null 2>&1 && make -j"$(nproc)" >/dev/null 2>&1 && make install >/dev/null 2>&1 )
    ok "libevent built into $prefix"
  fi

  # Provide a yacc stub if bison/yacc is missing — release tarballs
  # ship pre-generated parser files so yacc is not actually needed.
  local yacc_stub=""
  if ! command -v yacc &>/dev/null && ! command -v bison &>/dev/null; then
    yacc_stub="$tmp/bin/yacc"
    mkdir -p "$tmp/bin"
    printf '#!/bin/sh\necho yacc stub\n' > "$yacc_stub"
    chmod +x "$yacc_stub"
  fi

  # Build tmux
  local tarball="tmux-${TMUX_REQUIRED_VERSION}a.tar.gz"
  local url="https://github.com/tmux/tmux/releases/download/${TMUX_REQUIRED_VERSION}a/${tarball}"

  curl -fsSL "$url" -o "$tmp/$tarball"
  tar xzf "$tmp/$tarball" -C "$tmp"

  (
    cd "$tmp/tmux-${TMUX_REQUIRED_VERSION}a"
    PATH="${tmp}/bin:$PATH" \
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
    CFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib -Wl,-rpath,$prefix/lib" \
    ./configure --prefix="$prefix" >/dev/null 2>&1
    make -j"$(nproc)" >/dev/null 2>&1
    make install >/dev/null 2>&1
  )

  rm -rf "$tmp"

  if [ -x "$prefix/bin/tmux" ]; then
    ok "tmux installed: $("$prefix/bin/tmux" -V)"
  else
    err "tmux build failed"
  fi
}

# ── Worktrunk ────────────────────────────────────────────────────────────────

install_worktrunk() {
  if command -v wt &>/dev/null; then
    ok "worktrunk already installed: $(wt --version 2>&1 | head -1)"
    return
  fi

  info "Installing worktrunk..."
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  if [ "$os" = "darwin" ] && command -v brew &>/dev/null; then
    brew install worktrunk
  else
    # Linux / macOS without brew: prebuilt static binary via shell installer
    curl --proto '=https' --tlsv1.2 -LsSf \
      https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-installer.sh | sh
  fi

  ok "worktrunk installed"
}

setup_worktrunk_symlinks() {
  info "Linking worktrunk config..."
  link_it "$DOTFILES_DIR/worktrunk/config.toml" "$HOME/.config/worktrunk/config.toml"
}

# ── tuicr ─────────────────────────────────────────────────────────────────────

install_tuicr() {
  if command -v tuicr &>/dev/null; then
    ok "tuicr already installed: $(tuicr --version 2>&1 | head -1)"
    return
  fi

  info "Installing tuicr..."
  curl -fsSL https://tuicr.dev/install.sh | sh

  ok "tuicr installed"

# ── Chrome DevTools MCP ──────────────────────────────────────────────────────

install_chrome_for_mcp() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  if [ "$os" = "darwin" ]; then
    ok "macOS detected — system Chrome will be used for MCP (skipping download)"
    return
  fi

  # Linux: check Puppeteer cache for existing Chrome
  local chrome_found=false
  for candidate in "$HOME"/.cache/puppeteer/chrome/*/chrome-linux64/chrome; do
    if [ -x "$candidate" ]; then
      chrome_found=true
      ok "Chrome already installed in Puppeteer cache: $candidate"
      break
    fi
  done

  if [ "$chrome_found" = true ]; then
    return
  fi

  info "Downloading Chrome via Puppeteer (no sudo required)..."
  local bun_cmd
  bun_cmd="$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")"
  "$bun_cmd" x puppeteer browsers install chrome@stable
  ok "Chrome downloaded to ~/.cache/puppeteer/"
}

setup_chrome_devtools_mcp() {
  local wrapper_dest="$HOME/.local/bin/chrome-devtools-mcp"
  local wrapper_src="$DOTFILES_DIR/opencode/chrome-devtools-mcp"

  mkdir -p "$HOME/.local/bin"

  if [ ! -f "$wrapper_src" ]; then
    warn "chrome-devtools-mcp wrapper not found in dotfiles — skipping"
    return
  fi

  cp "$wrapper_src" "$wrapper_dest"
  chmod +x "$wrapper_dest"
  ok "chrome-devtools-mcp wrapper installed to $wrapper_dest"
}

validate_chrome_libs() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  if [ "$os" != "linux" ]; then
    return
  fi

  info "Checking required shared libraries for headless Chrome..."
  local missing=()
  local libs=(
    libX11.so.6
    libXcomposite.so.1
    libXdamage.so.1
    libXext.so.6
    libXfixes.so.3
    libXrandr.so.2
    libgbm.so.1
    libpango-1.0.so.0
    libcairo.so.2
    libasound.so.2
    libatk-1.0.so.0
    libatk-bridge-2.0.so.0
    libcups.so.2
    libdrm.so.2
    libdbus-1.so.3
    libnspr4.so
    libnss3.so
    libnssutil3.so
    libsmime3.so
    libxcb.so.1
    libxkbcommon.so.0
    libexpat.so.1
  )

  for lib in "${libs[@]}"; do
    if ! ldconfig -p 2>/dev/null | grep -q "$lib"; then
      missing+=("$lib")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    ok "All required Chrome libraries found"
  else
    warn "Missing libraries for headless Chrome (it may not work):"
    for lib in "${missing[@]}"; do
      echo "  - $lib"
    done
  fi
}

# ── OpenCode profile setup ───────────────────────────────────────────────────

has_personal_profile() {
  [ -f "$HOME/.local/bin/opencode" ] && grep -q "opencode-personal" "$HOME/.local/bin/opencode" 2>/dev/null
}

has_work_profile() {
  # Work can be the default wrapper or a separate opencode-work wrapper
  { [ -f "$HOME/.local/bin/opencode" ] && grep -q "opencode-work" "$HOME/.local/bin/opencode" 2>/dev/null; } ||
  { [ -f "$HOME/.local/bin/opencode-work" ] && grep -q "opencode-work" "$HOME/.local/bin/opencode-work" 2>/dev/null; }
}

prompt_opencode_profile() {
  # Allow non-interactive override via OPENCODE_PROFILE env var
  if [ -n "${OPENCODE_PROFILE:-}" ]; then
    echo "$OPENCODE_PROFILE"
    return
  fi

  local has_personal=false has_work=false
  has_personal_profile && has_personal=true
  has_work_profile && has_work=true

  # Both already installed — nothing to do
  if $has_personal && $has_work; then
    ok "OpenCode profiles already installed (personal + work)" >&2
    echo "both"
    return
  fi

  # Build options list based on what's missing
  declare -a labels=()
  declare -a values=()

  if $has_personal; then
    ok "Personal profile already installed" >&2
    # Only offer: work, both
    labels+=("work      — add work profile")
    values+=("work")
    labels+=("both      — personal (default) + work")
    values+=("both")
  elif $has_work; then
    ok "Work profile already installed" >&2
    # Only offer: personal, both
    labels+=("personal  — add personal profile")
    values+=("personal")
    labels+=("both      — personal (default) + work")
    values+=("both")
  else
    # Neither installed — offer all three
    labels+=("personal  — single personal profile")
    values+=("personal")
    labels+=("work      — single work profile")
    values+=("work")
    labels+=("both      — personal (default) + work")
    values+=("both")
  fi

  echo >&2
  info "OpenCode profile setup" >&2

  local idx
  idx=$(printf '%s\n' "${labels[@]}" | arrow_select) || {
    warn "Cancelled — defaulting to 'personal'" >&2
    echo "personal"
    return
  }

  echo "${values[$idx]}"
}

create_wrapper() {
  local name="$1" profile="$2" data_dir="$3"
  local wrapper="$HOME/.local/bin/$name"

  mkdir -p "$HOME/.local/bin"
  cat > "$wrapper" <<'OUTER'
#!/bin/bash
OUTER
  cat >> "$wrapper" <<EOF
# $name — OpenCode $profile profile
export XDG_DATA_HOME="\${HOME}/.local/share/opencode-$profile"
EOF
  cat >> "$wrapper" <<'OUTER'
# Fix Anthropic OAuth plugin to use a fixed port on servers (for SSH port forwarding).
# Local Mac uses the default random port (no patch) to avoid conflicts with tunnels.
# Each server gets a unique port derived from its hostname (range 45543–46542).
_auth_js="$HOME/.cache/opencode/node_modules/@ex-machina/opencode-anthropic-auth/dist/auth.js"
if [ -f "$_auth_js" ] && [ "$(uname -s)" = "Linux" ]; then
  _auth_port=$(( 45543 + $(hostname | cksum | cut -d' ' -f1) % 1000 ))
  if grep -q 'server\.listen(0,' "$_auth_js" 2>/dev/null; then
    sed -i.bak "s/server\.listen(0,/server.listen($_auth_port,/" "$_auth_js" && rm -f "$_auth_js.bak"
  elif grep -q 'server\.listen([0-9]' "$_auth_js" 2>/dev/null; then
    # Already patched — update to this server's port
    sed -i.bak "s/server\.listen([0-9]*,/server.listen($_auth_port,/" "$_auth_js" && rm -f "$_auth_js.bak"
  fi
fi
# Restart agent-notify daemon if ntfy tunnel may have reconnected (Linux servers)
if command -v systemctl &>/dev/null && systemctl --user is-enabled agent-notify-daemon &>/dev/null 2>&1; then
  systemctl --user restart agent-notify-daemon 2>/dev/null
fi
exec ~/.opencode/bin/opencode "$@"
OUTER
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
      create_wrapper "opencode-work" "work" "$HOME/.local/share/opencode-work"
      # Symlink opencode -> opencode-work for convenience (single profile)
      ln -sf "$HOME/.local/bin/opencode-work" "$HOME/.local/bin/opencode"
      ok "Symlinked opencode -> opencode-work"
      ;;
    both)
      create_wrapper "opencode" "personal" "$HOME/.local/share/opencode-personal"
      create_wrapper "opencode-work" "work" "$HOME/.local/share/opencode-work"
      ;;
  esac
}

# ── Anthropic auth plugin: fixed OAuth port ──────────────────────────────────

patch_anthropic_auth_port() {
  # Only patch on servers — local Mac uses the default random port
  if [ "$(uname -s)" = "Darwin" ]; then
    ok "Local Mac — skipping auth port patch (uses random port)"
    return
  fi

  local auth_js="$HOME/.cache/opencode/node_modules/@ex-machina/opencode-anthropic-auth/dist/auth.js"
  if [ ! -f "$auth_js" ]; then
    info "Anthropic auth plugin not cached yet — port patch will apply via wrapper on first run"
    return
  fi

  local auth_port=$(( 45543 + $(hostname | cksum | cut -d' ' -f1) % 1000 ))

  if grep -q "server\.listen(${auth_port}," "$auth_js" 2>/dev/null; then
    ok "Anthropic auth plugin already patched to port $auth_port"
    return
  fi

  # Patch whether it's the default port 0 or a previously patched port
  sed -i.bak "s/server\.listen([0-9]*,/server.listen(${auth_port},/" "$auth_js" && rm -f "$auth_js.bak"
  ok "Patched Anthropic auth plugin to use port $auth_port (derived from hostname)"
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
  link_it "$DOTFILES_DIR/opencode/rules"          "$HOME/.config/opencode/rules"
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
  link_it "$DOTFILES_DIR/tmux/.tmux.conf" "$HOME/.tmux.conf"
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
  echo "    - Worktrunk config          (~/.config/worktrunk/)"
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

  # Worktrunk config
  if [ -L "$HOME/.config/worktrunk/config.toml" ]; then
    rm "$HOME/.config/worktrunk/config.toml"
    ok "Removed worktrunk config symlink"
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

# ── Uninstall single profile ────────────────────────────────────────────────

uninstall_profile() {
  local profile="$1"

  if [ "$profile" != "personal" ] && [ "$profile" != "work" ]; then
    err "Invalid profile: $profile (must be 'personal' or 'work')"
    exit 1
  fi

  # Determine which wrapper name this profile uses
  local wrapper=""
  if [ "$profile" = "personal" ]; then
    # Personal always uses the 'opencode' wrapper
    if [ -f "$HOME/.local/bin/opencode" ] && grep -q "opencode-personal" "$HOME/.local/bin/opencode" 2>/dev/null; then
      wrapper="opencode"
    fi
  else
    # Work uses 'opencode-work' in dual mode, or 'opencode' in single mode
    if [ -f "$HOME/.local/bin/opencode-work" ] && grep -q "opencode-work" "$HOME/.local/bin/opencode-work" 2>/dev/null; then
      wrapper="opencode-work"
    elif [ -f "$HOME/.local/bin/opencode" ] && grep -q "opencode-work" "$HOME/.local/bin/opencode" 2>/dev/null; then
      wrapper="opencode"
    fi
  fi

  local data_dir="$HOME/.local/share/opencode-$profile"

  echo
  warn "This will remove the '$profile' OpenCode profile."
  echo
  echo "  The following will be REMOVED:"
  [ -n "$wrapper" ] && echo "    - Wrapper script  (~/.local/bin/$wrapper)"
  [ -d "$data_dir" ] && echo "    - Data directory  ($data_dir)"
  echo
  printf "  Type 'yes' to confirm: "
  read -r confirm

  if [ "$confirm" != "yes" ]; then
    info "Cancelled."
    return
  fi

  echo

  if [ -n "$wrapper" ] && [ -f "$HOME/.local/bin/$wrapper" ]; then
    rm "$HOME/.local/bin/$wrapper"
    ok "Removed ~/.local/bin/$wrapper"
  fi

  # Remove convenience symlink if it points to the removed wrapper
  if [ -L "$HOME/.local/bin/opencode" ] && \
     [ "$(readlink "$HOME/.local/bin/opencode")" = "$HOME/.local/bin/$wrapper" ]; then
    rm "$HOME/.local/bin/opencode"
    ok "Removed opencode symlink"
  fi

  if [ -d "$data_dir" ]; then
    rm -rf "$data_dir"
    ok "Removed $data_dir"
  fi

  echo
  ok "Profile '$profile' uninstalled."
  info "Shared components (binary, config, cache) were kept — they may be used by other profiles."
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 [--uninstall] [--uninstall-profile personal|work]"
  echo
  echo "  install.sh                              Install dotfiles, tools, and OpenCode profiles"
  echo "  install.sh --uninstall                   Remove all dotfile-managed installations"
  echo "  install.sh --uninstall-profile personal  Remove only the personal OpenCode profile"
  echo "  install.sh --uninstall-profile work      Remove only the work OpenCode profile"
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

  if [ "${1:-}" = "--uninstall-profile" ]; then
    if [ -z "${2:-}" ]; then
      err "Missing profile name. Usage: $0 --uninstall-profile personal|work"
      exit 1
    fi
    uninstall_profile "$2"
    exit 0
  fi

  if [ "${1:-}" = "--uninstall" ]; then
    uninstall
    exit 0
  fi

  info "dotfiles dir: $DOTFILES_DIR"
  echo

  ensure_path
  install_bun
  install_nvim
  install_tmux
  install_opencode_binary
  install_openspec
  install_worktrunk
  install_tuicr
  setup_shell
  setup_symlinks

  # OpenCode profile selection + config
  local profile
  profile="$(prompt_opencode_profile)"
  info "Setting up OpenCode with profile: $profile"
  setup_opencode_profiles "$profile"
  setup_opencode_symlinks
  patch_anthropic_auth_port
  setup_worktrunk_symlinks
  setup_agent_notify

  echo
  ok "All done! Restart your shell or run: source ~/.bashrc"
  info "Run 'wt config shell install' once to enable shell integration (cd on switch)."
}

# ── agent-notify ─────────────────────────────────────────────────────────────

AN_DIR="$DOTFILES_DIR/agent-notify"
AN_SECRETS="$HOME/.config/agent-notify/secrets"
AN_LOG_DIR="$HOME/.local/share/agent-notify/logs"

setup_agent_notify() {
  info "Setting up agent-notify..."

  # Ensure directories
  mkdir -p "$HOME/.config/agent-notify"
  mkdir -p "$AN_LOG_DIR"
  mkdir -p "$HOME/.local/share/agent-notify"

  # Determine role first — it gates what gets installed
  local role
  role="$(agent_notify_read_role)"

  # Plugin symlink (both roles need this)
  agent_notify_plugin_symlink

  # ntfy topics are needed on both (servers publish, main subscribes)
  agent_notify_ntfy_setup

  if [ "$role" = "server" ]; then
    # Servers need Telegram for remote notifications
    agent_notify_telegram_setup
  else
    ok "Main machine — skipping Telegram (native notifications only)"
  fi

  # Service installation
  agent_notify_install_services "$role"

  # Post-install validation
  agent_notify_validate "$role"
}

agent_notify_plugin_symlink() {
  link_it "$AN_DIR/../opencode/plugins/agent-notify.ts" \
          "$HOME/.config/opencode/plugins/agent-notify.ts"
  link_it "$AN_DIR/notify-panel.sh" "$HOME/.local/bin/agent-notify-panel"
}

agent_notify_read_role() {
  local config="$AN_DIR/config.toml"
  local role=""

  # Seed from example template if config doesn't exist yet
  if [ ! -f "$config" ] && [ -f "$config.example" ]; then
    cp "$config.example" "$config"
    ok "Created config.toml from template"
  fi

  if [ -f "$config" ]; then
    role="$(grep -E '^role[[:space:]]*=' "$config" | sed 's/.*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/' | head -1)"
  fi

  # If role is set and valid, use it
  if [ "$role" = "main" ] || [ "$role" = "server" ]; then
    echo "$role"
    return
  fi

  # Not set or invalid — prompt interactively
  echo >&2
  info "Machine role" >&2
  echo "  main   = your Mac — native notifications only, no Telegram" >&2
  echo "  server = remote machine — daemon + Telegram for notifications" >&2

  local idx
  idx=$(printf '%s\n' "main    — Mac with native notifications only" "server  — remote machine with Telegram" | arrow_select) || {
    warn "Cancelled — defaulting to 'server'" >&2
    echo "server"
    return
  }

  if [ "$idx" = "0" ]; then
    role="main"
  else
    role="server"
  fi

  # Write role back to config.toml (uncomment if needed, or update in place)
  if [ -f "$config" ]; then
    if grep -qE '^role[[:space:]]*=' "$config"; then
      sed -i.bak 's/^role[[:space:]]*=.*/role = "'"$role"'"/' "$config" && rm -f "$config.bak"
    elif grep -qE '^#[[:space:]]*role[[:space:]]*=' "$config"; then
      sed -i.bak 's/^#[[:space:]]*role[[:space:]]*=.*/role = "'"$role"'"/' "$config" && rm -f "$config.bak"
    else
      sed -i.bak '/Machine role/a\
role = "'"$role"'"' "$config" && rm -f "$config.bak"
    fi
  fi

  echo "$role"
}

# ── Telegram interactive setup ───────────────────────────────────────────────

agent_notify_telegram_setup() {
  if [ -f "$AN_SECRETS" ] && grep -q "AGENT_NOTIFY_BOT_TOKEN=." "$AN_SECRETS" 2>/dev/null; then
    ok "Telegram already configured"
    return
  fi

  echo
  info "Telegram bot setup"
  echo "  Create a bot via @BotFather on Telegram, then paste the token below."
  echo

  local token=""
  while true; do
    printf "  Bot token: "
    read -r token
    if [ -z "$token" ]; then
      warn "Token cannot be empty"
      continue
    fi

    # Validate via getMe
    local me_result
    me_result="$(curl -s "https://api.telegram.org/bot${token}/getMe")"
    if echo "$me_result" | grep -q '"ok":true'; then
      local bot_name
      bot_name="$(echo "$me_result" | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)"
      ok "Bot @${bot_name} found"
      break
    else
      err "Invalid token. Try again."
    fi
  done

  # Detect chat ID
  echo
  info "Now send any message to @${bot_name:-your bot} on Telegram, then press Enter."
  printf "  Press Enter after sending a message..."
  read -r

  local chat_id=""
  local attempts=0
  while [ -z "$chat_id" ] && [ "$attempts" -lt 3 ]; do
    local updates
    updates="$(curl -s "https://api.telegram.org/bot${token}/getUpdates")"
    chat_id="$(echo "$updates" | grep -o '"chat":{"id":[0-9-]*' | head -1 | grep -o '[0-9-]*$')"
    if [ -z "$chat_id" ]; then
      attempts=$((attempts + 1))
      if [ "$attempts" -lt 3 ]; then
        warn "No message found. Make sure you sent a message to the bot. Press Enter to retry..."
        read -r
      fi
    fi
  done

  if [ -z "$chat_id" ]; then
    err "Could not detect chat ID. You can set it manually in $AN_SECRETS"
    chat_id="CHANGE_ME"
  else
    ok "Chat ID detected: $chat_id"

    # Send test message
    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${chat_id}\",\"text\":\"agent-notify setup complete!\"}" >/dev/null
    ok "Test message sent to Telegram"
  fi

  # Write secrets
  cat > "$AN_SECRETS" <<EOF
AGENT_NOTIFY_BOT_TOKEN=${token}
AGENT_NOTIFY_CHAT_ID=${chat_id}
EOF

  # Preserve existing ntfy topics if present
  if [ -f "$AN_SECRETS.bak" ]; then
    grep "AGENT_NOTIFY_NTFY" "$AN_SECRETS.bak" >> "$AN_SECRETS" 2>/dev/null || true
    rm -f "$AN_SECRETS.bak"
  fi

  chmod 600 "$AN_SECRETS"
  ok "Secrets saved to $AN_SECRETS"
}

# ── ntfy topic auto-generation ───────────────────────────────────────────────

agent_notify_ntfy_setup() {
  if [ -f "$AN_SECRETS" ] && grep -q "AGENT_NOTIFY_NTFY_EVENTS=." "$AN_SECRETS" 2>/dev/null; then
    ok "ntfy topics already configured"
    return
  fi

  local events_topic="an-$(openssl rand -hex 12)"
  local ack_topic="an-ack-$(openssl rand -hex 12)"

  # Ensure secrets file exists (main machine skips Telegram setup)
  touch "$AN_SECRETS"

  # Append to secrets (don't overwrite Telegram values)
  {
    echo "AGENT_NOTIFY_NTFY_EVENTS=${events_topic}"
    echo "AGENT_NOTIFY_NTFY_ACK=${ack_topic}"
  } >> "$AN_SECRETS"

  chmod 600 "$AN_SECRETS"
  ok "ntfy topics generated: ${events_topic}, ${ack_topic}"
}

# ── terminal-notifier (dismissable macOS notifications) ──────────────────────

install_ntfy_server() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ntfy$'; then
    ok "ntfy server already running"
    return
  fi

  if ! command -v docker &>/dev/null; then
    warn "Docker not found — install Docker to run self-hosted ntfy"
    return
  fi

  info "Starting self-hosted ntfy server via Docker..."
  mkdir -p "$HOME/.local/share/ntfy/cache"
  docker run -d --name ntfy --restart unless-stopped \
    -p 8090:80 \
    -v "$HOME/.local/share/ntfy/cache:/var/cache/ntfy" \
    binwiederhier/ntfy serve --cache-file /var/cache/ntfy/cache.db \
    >/dev/null 2>&1
  ok "ntfy server running on http://localhost:8090"
}

install_terminal_notifier() {
  if command -v terminal-notifier &>/dev/null; then
    ok "terminal-notifier already installed"
    return
  fi

  if command -v brew &>/dev/null; then
    info "Installing terminal-notifier via Homebrew..."
    brew install terminal-notifier
    ok "terminal-notifier installed"
  else
    warn "Homebrew not found — install terminal-notifier manually: brew install terminal-notifier"
  fi
}

# ── Service installation ─────────────────────────────────────────────────────

agent_notify_install_services() {
  local role="$1"
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  local bun_path
  bun_path="$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")"
  local current_path="$PATH"

  if [ "$role" = "main" ]; then
    # Main machine: daemon (ntfy only, no Telegram) + listener
    if [ "$os" = "darwin" ]; then
      install_ntfy_server
      install_terminal_notifier
      agent_notify_install_launchd_daemon "$bun_path" "$current_path"
      agent_notify_install_launchd_listener "$bun_path" "$current_path"
    fi
  else
    # Server: daemon only — no listener
    if [ "$os" = "darwin" ]; then
      agent_notify_install_launchd_daemon "$bun_path" "$current_path"
    elif [ "$os" = "linux" ]; then
      agent_notify_install_systemd_daemon "$bun_path" "$current_path"
    fi
  fi
}

agent_notify_install_launchd_daemon() {
  local bun_path="$1" current_path="$2"
  local plist_src="$AN_DIR/com.agkhalil.agent-notify-daemon.plist"
  local plist_dst="$HOME/Library/LaunchAgents/com.agkhalil.agent-notify-daemon.plist"
  local label="com.agkhalil.agent-notify-daemon"

  mkdir -p "$HOME/Library/LaunchAgents"

  # Unload if already loaded
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true

  # Generate plist from template
  sed \
    -e "s|__BUN_PATH__|${bun_path}|g" \
    -e "s|__DAEMON_PATH__|${AN_DIR}/daemon.ts|g" \
    -e "s|__LOG_DIR__|${AN_LOG_DIR}|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__PATH__|${current_path}|g" \
    "$plist_src" > "$plist_dst"

  launchctl bootstrap "gui/$(id -u)" "$plist_dst"
  ok "Daemon launchd service installed and started"
}

agent_notify_install_launchd_listener() {
  local bun_path="$1" current_path="$2"
  local plist_src="$AN_DIR/com.agkhalil.agent-notify-listener.plist"
  local plist_dst="$HOME/Library/LaunchAgents/com.agkhalil.agent-notify-listener.plist"
  local label="com.agkhalil.agent-notify-listener"

  mkdir -p "$HOME/Library/LaunchAgents"

  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true

  sed \
    -e "s|__BUN_PATH__|${bun_path}|g" \
    -e "s|__LISTENER_PATH__|${AN_DIR}/listener.ts|g" \
    -e "s|__LOG_DIR__|${AN_LOG_DIR}|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__PATH__|${current_path}|g" \
    "$plist_src" > "$plist_dst"

  launchctl bootstrap "gui/$(id -u)" "$plist_dst"
  ok "Listener launchd service installed and started"
}

agent_notify_install_systemd_daemon() {
  local bun_path="$1" current_path="$2"
  local unit_src="$AN_DIR/agent-notify-daemon.service"
  local unit_dst="$HOME/.config/systemd/user/agent-notify-daemon.service"

  mkdir -p "$HOME/.config/systemd/user"

  sed \
    -e "s|__BUN_PATH__|${bun_path}|g" \
    -e "s|__DAEMON_PATH__|${AN_DIR}/daemon.ts|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__PATH__|${current_path}|g" \
    "$unit_src" > "$unit_dst"

  systemctl --user daemon-reload
  systemctl --user enable --now agent-notify-daemon
  ok "Daemon systemd service installed and started"
}

# ── Post-install validation ──────────────────────────────────────────────────

agent_notify_validate() {
  local role="$1"
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  local all_ok=true

  echo
  info "Validating agent-notify installation..."

  # Check plugin symlink
  if [ -L "$HOME/.config/opencode/plugins/agent-notify.ts" ]; then
    ok "Plugin symlinked"
  else
    err "Plugin symlink missing"
    all_ok=false
  fi

  # Check ntfy topics (both roles need these)
  if [ -f "$AN_SECRETS" ] && grep -q "AGENT_NOTIFY_NTFY_EVENTS=." "$AN_SECRETS" 2>/dev/null; then
    ok "ntfy topics configured"
  else
    warn "ntfy topics not configured"
    all_ok=false
  fi

  if [ "$role" = "main" ]; then
    # Main: daemon (ntfy only) + listener
    if [ "$os" = "darwin" ]; then
      if launchctl list 2>/dev/null | grep -q "agent-notify-daemon"; then
        ok "Daemon running (launchd)"
      else
        warn "Daemon not detected in launchctl"
        all_ok=false
      fi
      if launchctl list 2>/dev/null | grep -q "agent-notify-listener"; then
        ok "Listener running (launchd)"
      else
        warn "Listener not detected in launchctl"
        all_ok=false
      fi
    fi
  else
    # Server: daemon + Telegram
    if [ -f "$AN_SECRETS" ] && grep -q "AGENT_NOTIFY_BOT_TOKEN=." "$AN_SECRETS"; then
      ok "Telegram secrets configured"
    else
      err "Telegram secrets not configured"
      all_ok=false
    fi

    if [ "$os" = "darwin" ]; then
      if launchctl list 2>/dev/null | grep -q "agent-notify-daemon"; then
        ok "Daemon running (launchd)"
      else
        warn "Daemon not detected in launchctl"
        all_ok=false
      fi
    elif [ "$os" = "linux" ]; then
      if systemctl --user is-active agent-notify-daemon >/dev/null 2>&1; then
        ok "Daemon running (systemd)"
      else
        warn "Daemon not active"
        all_ok=false
      fi
    fi

    # Validate bot token
    local token
    token="$(grep 'AGENT_NOTIFY_BOT_TOKEN=' "$AN_SECRETS" 2>/dev/null | cut -d'=' -f2)"
    if [ -n "$token" ] && [ "$token" != "CHANGE_ME" ]; then
      local me_result
      me_result="$(curl -s "https://api.telegram.org/bot${token}/getMe" 2>/dev/null)"
      if echo "$me_result" | grep -q '"ok":true'; then
        ok "Telegram bot token valid"
      else
        warn "Telegram bot token invalid"
        all_ok=false
      fi
    fi
  fi

  echo
  if [ "$all_ok" = true ]; then
    ok "agent-notify validation passed"
  else
    warn "Some checks failed — see above"
  fi
}

main "$@"
