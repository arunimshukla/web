#!/usr/bin/env bash
set -euo pipefail

CANDIDATE_SHA="891a535c78045ffbc9f2a38de3cfc28e0cf78843"
BASELINE_SHA="3330621002207df1135787d66eb93c25792c773b"
CANDIDATE_DIR="/tmp/map-sync-candidate"
BASELINE_DIR="/tmp/map-sync-baseline"

rm -rf "$CANDIDATE_DIR" "$BASELINE_DIR"

git fetch --no-tags origin "$CANDIDATE_SHA" || true
git fetch --no-tags https://github.com/ethsystems/web.git "$BASELINE_SHA"

git worktree add --detach "$CANDIDATE_DIR" "$CANDIDATE_SHA"
git worktree add --detach "$BASELINE_DIR" "$BASELINE_SHA"

git -C "$CANDIDATE_DIR" submodule update --init --recursive
git -C "$BASELINE_DIR" submodule update --init --recursive

echo "=== CANDIDATE EXACT DIFF ==="
git -C "$CANDIDATE_DIR" diff --stat "$BASELINE_SHA..$CANDIDATE_SHA"
git -C "$CANDIDATE_DIR" diff "$BASELINE_SHA..$CANDIDATE_SHA" -- content
git -C "$CANDIDATE_DIR" diff --check "$BASELINE_SHA..$CANDIDATE_SHA"

echo "=== CANDIDATE VALIDATION ==="
cd "$CANDIDATE_DIR"
npm ci
npm run build:graph
npm test
npm run lint:refs
npm run build

set +e
npm run check 2>&1 | tee /tmp/candidate-check.log
candidate_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$candidate_status" > /tmp/candidate-check.status

echo "=== BASELINE ASTRO CHECK ==="
cd "$BASELINE_DIR"
npm ci
npm run build:graph

set +e
npm run check 2>&1 | tee /tmp/baseline-check.log
baseline_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$baseline_status" > /tmp/baseline-check.status

strip_ansi() {
  sed -r 's/\x1B\[[0-9;]*[mK]//g' "$1"
}

count_diag() {
  local kind="$1" file="$2" n
  n="$(strip_ansi "$file" | grep -Eo -- "- [0-9]+ ${kind}s?" | tail -1 | grep -Eo '[0-9]+' || true)"
  printf '%s' "${n:-0}"
}

be="$(count_diag error /tmp/baseline-check.log)"
bw="$(count_diag warning /tmp/baseline-check.log)"
bh="$(count_diag hint /tmp/baseline-check.log)"
ce="$(count_diag error /tmp/candidate-check.log)"
cw="$(count_diag warning /tmp/candidate-check.log)"
ch="$(count_diag hint /tmp/candidate-check.log)"
bs="$(cat /tmp/baseline-check.status)"
cs="$(cat /tmp/candidate-check.status)"

echo "ASTRO_CHECK_BASELINE status=$bs errors=$be warnings=$bw hints=$bh"
echo "ASTRO_CHECK_CANDIDATE status=$cs errors=$ce warnings=$cw hints=$ch"

if (( ce > be || cw > bw || ch > bh )); then
  echo "Candidate introduces new Astro diagnostics."
  exit 1
fi

echo "Candidate introduces no new Astro diagnostics by severity count."
echo "MAP_SYNC_VALIDATION=PASS"
