# Linked file by file: ~/.local/bin also holds installed binaries, which must
# not be shadowed by the repo.
bin_link() {
  link bin/wl-paste "$HOME/.local/bin/wl-paste"
  link bin/wl-copy "$HOME/.local/bin/wl-copy"
}
