#!/usr/bin/env bash
# Fail when a package imports a sibling at a version other than the sibling's
# VERSION at REF, or imports a sibling by hash. scripts/pins.allow lists the
# exceptions, one import target (bend-kit-<pkg>@<version> or 0x<hash>) per line.
# Usage: scripts/pins.sh [REF [pkg...]]. REF defaults to HEAD, packages to all.
set -euo pipefail
cd "$(dirname "$0")/.."

ref=${1:-HEAD}
[ $# -gt 0 ] && shift
[ $# -eq 0 ] && set -- $(scripts/packages.sh)
allow=$(sed 's/#.*//' scripts/pins.allow | awk 'NF { print $1 }')
hits=$(grep -rnE --include='*.bend' '^[[:space:]]*import[[:space:]]+(bend-kit-|0x)' "$@" || true)
bad=0
for target in $(sed -E 's/^[^:]*:[0-9]+:[[:space:]]*import[[:space:]]+([^/[:space:]]+).*/\1/' <<<"$hits" | sort -u); do
  grep -qxF "$target" <<<"$allow" && continue
  case $target in
    0x*) why="by hash; import the sibling by name" ;;
    *)
      name=${target%@*}
      name=${name#bend-kit-}
      want=$(git show "$ref:$name/VERSION" 2>/dev/null) || want=missing
      [ "${target#*@}" = "$want" ] && continue
      why="but $name/VERSION at $ref is $want"
      ;;
  esac
  grep -F "import $target/" <<<"$hits" | cut -d: -f1,2 | sed "s|\$|: imports $target $why|" >&2
  bad=1
done
exit $bad
