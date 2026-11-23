#!/usr/bin/env bash
set -euo pipefail

# Add a component by dropping install.d/<name>.sh in place, defining
# <name>_is_installed, <name>_install and <name>_uninstall. The name must be a
# valid shell function prefix (no dashes); components run in filename order.

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

sudo=()
[[ $EUID -eq 0 ]] || sudo=(sudo)

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

components=()
for module in "$root"/install.d/*.sh; do
  [[ -f $module ]] || die "No components found in $root/install.d"
  # shellcheck source=/dev/null
  source "$module"
  components+=("$(basename -- "$module" .sh)")
done

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
