#!/usr/bin/env bash
set -euo pipefail

# Add a component by defining <name>_is_installed, <name>_install and
# <name>_uninstall, then listing it in `components`.
components=(opencode claude)

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

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

install_component() {
  local name=$1 version
  if version=$("${name}_is_installed"); then
    printf '%s: already installed (%s)\n' "$name" "$version"
    return
  fi
  printf '%s: installing...\n' "$name"
  "${name}_install"
}

uninstall_component() {
  local name=$1
  if ! "${name}_is_installed" >/dev/null; then
    printf '%s: not installed\n' "$name"
    return
  fi
  printf '%s: uninstalling...\n' "$name"
  "${name}_uninstall"
}

# Fills `selected` with the component names the user picks.
select_components() {
  local input choice i
  local -a choices

  printf 'Select components to %s (space-separated numbers, or "all"):\n' "$1"
  for i in "${!components[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${components[i]}"
  done
  IFS= read -r -p '> ' input || true

  choices=()
  read -r -a choices <<< "$input"
  for choice in "${choices[@]}"; do
    if [[ $choice == all ]]; then
      selected=("${components[@]}")
      return
    fi
    [[ $choice =~ ^[1-9][0-9]*$ ]] && (( choice <= ${#components[@]} )) ||
      die "Invalid selection: $choice"
    selected+=("${components[choice - 1]}")
  done
}

run() {
  local action=$1 component
  shift
  for component in "$@"; do
    "${action}_component" "$component"
  done
}

case ${1:-} in
  '')
    run install "${components[@]}"
    ;;
  --install|--uninstall)
    action=${1#--}
    selected=()
    select_components "$action"
    run "$action" "${selected[@]}"
    ;;
  *)
    die "Usage: $0 [--install|--uninstall]"
    ;;
esac
