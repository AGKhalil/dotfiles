#!/usr/bin/env bash
set -euo pipefail

# Add a component by dropping link.d/<name>.sh in place, defining <name>_link
# (via the `link` helper) and optionally <name>_post_link. The name must be a
# valid shell function prefix (no dashes); components run in filename order.

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

# link <path in this repo> <destination>
link() {
  mkdir -p -- "$(dirname -- "$2")"
  ln -sfn -- "$root/$1" "$2"
  printf '%s -> %s\n' "$2" "$root/$1"
}

components=()
for module in "$root"/link.d/*.sh; do
  [[ -f $module ]] || die "No components found in $root/link.d"
  # shellcheck source=/dev/null
  source "$module"
  components+=("$(basename -- "$module" .sh)")
done

for component in "${components[@]}"; do
  "${component}_link"
  if declare -F "${component}_post_link" >/dev/null; then
    "${component}_post_link"
  fi
done
