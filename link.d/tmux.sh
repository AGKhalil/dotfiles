tmux_link() {
  link tmux/tmux.conf "$HOME/.config/tmux/tmux.conf"
}

# Reloads running sessions; silent when no server is up.
tmux_post_link() {
  tmux source-file "$HOME/.config/tmux/tmux.conf" 2>/dev/null || true
}
