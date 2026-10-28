#!/bin/sh
# Decompiles every function of each target with rea + Ghidra into OUT/<name>/functions/*.c
# usage: . re/scripts/rea-env.sh && re/scripts/decompile.sh TARGETS_DIR OUT
set -eu
TARGETS="$1"; OUT="$2"; mkdir -p "$OUT"
for t in escargot.dll msnmsgr.exe; do
	name="${t%.*}"
	rea decompile-all "$TARGETS/$t" --output "$OUT/$name" --provider ghidra --json > "$OUT/$name.manifest.json"
done
