# Latest stable release under ~/.local/nvim, linked into ~/.local/bin.
nvim_is_installed() {
  export PATH="$HOME/.local/bin:$PATH"
  local version
  version=$(nvim --version 2>/dev/null | head -1) || return 1
  printf '%s' "${version#NVIM }"
}

nvim_install() {
  local arch=x86_64 tmp
  [[ $(uname -m) == x86_64 ]] || arch=arm64
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$arch.tar.gz" |
    tar -xzf - -C "$tmp" --strip-components=1
  rm -rf -- "$HOME/.local/nvim"
  mkdir -p -- "$HOME/.local/bin"
  mv -- "$tmp" "$HOME/.local/nvim"
  ln -sf -- "$HOME/.local/nvim/bin/nvim" "$HOME/.local/bin/nvim"
}

# Leaves ~/.config/nvim and ~/.local/share/nvim in place.
nvim_uninstall() {
  rm -f -- "$HOME/.local/bin/nvim"
  rm -rf -- "$HOME/.local/nvim"
}
