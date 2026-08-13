#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

# sudo resolves a bare command name against secure_path, never the caller's
# PATH. A dev-linked checkout only joins secure_path through the drop-in
# omarchy-dev-link writes, so on a machine linked before that shipped, `sudo
# omarchy-foo` is a command not found -- and since omarchy-migrate runs each
# migration under `bash -euo pipefail`, that failure stops every migration
# behind it too. Calling through $OMARCHY_PATH/bin sidesteps secure_path
# entirely, and resolves on a packaged install as well, where the same names are
# symlinks to /usr/bin.

offenders=()
while IFS= read -r offender; do
  [[ -n $offender ]] && offenders+=("$offender")
done < <(grep -rn '\bsudo \+omarchy-' "$ROOT/migrations" 2>/dev/null || true)

(( ${#offenders[@]} == 0 )) ||
  fail "migrations call omarchy commands by path, not through sudo's PATH" \
    "$(printf '%s\n' "${offenders[@]}")"

pass "no migration invokes an omarchy command by bare name under sudo"
