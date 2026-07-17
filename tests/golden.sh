#!/usr/bin/env bash
# Golden tests (DESIGN.md §5): the evaluator is deterministic (fixed seeds, no
# wall-clock, no global rand), so eval stats + the topo oracle's output hash
# stably. Every content/samples/<name>.strata.svg has a sibling
# <name>.golden.txt holding `strata eval` + `strata topo` output (stdout and
# stderr — skip warnings are part of the contract).
#
#   tests/golden.sh            build + compare all samples
#   tests/golden.sh --update   regenerate the goldens (review the diff!)
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null

update=false
[[ "${1:-}" == "--update" ]] && update=true

fail=0
for doc in content/samples/*.strata.svg; do
	name="$(basename "${doc%.strata.svg}")"
	golden="content/samples/$name.golden.txt"
	out="$({ tool/strata eval "$doc"; echo "---"; tool/strata topo "$doc"; } 2>&1)"
	if $update; then
		printf '%s\n' "$out" >"$golden"
		echo "updated $golden"
	elif [[ ! -f "$golden" ]]; then
		echo "MISSING $golden (run tests/golden.sh --update)"
		fail=1
	elif ! diff -u "$golden" <(printf '%s\n' "$out"); then
		echo "FAIL $name"
		fail=1
	else
		echo "ok   $name"
	fi
done
exit $fail
