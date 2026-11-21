#!/usr/bin/env bash
# Rejoue un test N fois et garde chaque sortie et trace : ./repeat.sh <nom-test> <N> <étiquette>
set -uo pipefail
cd "$(dirname "$0")"
for i in $(seq "$2"); do
    FILTRE="$1" ./driver.sh tests > /dev/null 2>&1
    j="journaux/${MODE:-direct}"; cp "$j/$1.txt" "$j/$1.$3.$i.txt"; cp "$j/$1.trace" "$j/$1.$3.$i.trace"
    echo "$3 essai $i : $(grep -oE "tool=task [a-z-]+" "$j/$1.trace" | sort -u | tr '\n' ' ' || true)"
done
