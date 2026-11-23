tmux_is_installed() {
  command -v tmux >/dev/null 2>&1 || return 1
  printf '%s' "$(tmux -V 2>/dev/null)"
}

tmux_install() {
  "${sudo[@]}" apt-get update
  "${sudo[@]}" apt-get install -y tmux
}

# Leaves ~/.tmux.conf in place.
tmux_uninstall() {
  "${sudo[@]}" apt-get remove -y tmux
}
