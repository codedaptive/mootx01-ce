#!/bin/zsh
# Smoke gate — builds the test vehicle, echoes the checklist, runs the
# automated shape review, and stamps green so the full build may run.
#
# A smoke test is ONE short pass that produces a specimen, followed by a
# thorough review that the data is EXACTLY the shape it is supposed to be
# (smoke doctrine, operator ruling 2026-08-28). The full-build make targets refuse to
# run until this gate has stamped green.
#
# usage: smoke_gate.sh <seed> <estate-dir> <stamp> <window-seconds>
#                      [verify-extra-args...] -- <build command...>
#
# The build command runs for at most <window-seconds>. If it completes
# inside the window the specimen is verified strictly and KEPT (it is the
# real artifact). If the window expires the build is stopped (driver and
# its serve child), the specimen is verified in --partial mode (counts
# bounded by the seed, no foreign rows, zero charters), and then DELETED —
# import is strict-append, a stopped estate is not resumable.
set -u
seed=$1; estate_dir=$2; stamp=$3; window=$4; shift 4
verify_args=()
while [[ $# -gt 0 && "$1" != "--" ]]; do verify_args+=("$1"); shift; done
shift  # the --

here=${0:A:h}

cat <<'CHECKLIST'
smoke checklist — every line must be PASS before the full build runs:
  1. drawers == seed records          (exact; probe mode: <= with no foreign rows)
  2. zero charter sentinel ids        (00000000-...-0001..7 — THE gate)
  3. kg_facts == seed facts
  4. tunnels == seed tunnels
  5. corpus_index_state == drawers    (encode coverage; informational in probe mode)
  6. room distribution == projection  (per-name counts; no foreign rooms)
  7. wing distribution == projection  (per-name counts; no foreign wings)
  8. subject wrapper verbatim         (sampled across the seed)
  9. plaintext posture                (no db.key; plain SQLite header)
 10. estate format current
 11. no federation identity minted    (transient record non-federating by default)
 12. active encoder registered        (exactly one encoder_models row with is_active)
 13. span coverage matches eligible   (every live drawer span-indexed at current serving generation)
CHECKLIST

rm -f "$stamp"

# A converged existing estate IS the specimen: verify it strictly and
# stamp without rebuilding. This makes the smoke safe to run over READY
# production artifacts (the gate's job is the shape review, not churn).
# An estate that fails strict but passes --resumable (rows and shape
# exact; only encode or span coverage short) is ALSO kept and stamped —
# the full build's resume / span-short states converge exactly that
# shortfall, and tearing it down would discard hours of encode work.
# Anything short of both reviews is torn down and rebuilt from seed.
if [[ -d "$estate_dir" ]]; then
  if python3 "$here/smoke_verify.py" --seed "$seed" --estate-dir "$estate_dir" \
       "${verify_args[@]}"; then
    touch "$stamp"
    echo "smoke GATE OPEN (existing converged artifact verified): $stamp"
    exit 0
  fi
  if python3 "$here/smoke_verify.py" --seed "$seed" --estate-dir "$estate_dir" \
       --resumable "${verify_args[@]}"; then
    touch "$stamp"
    echo "smoke GATE OPEN (existing resumable artifact verified — the full" \
         "build resumes its encode/span shortfall): $stamp"
    exit 0
  fi
  echo "smoke: existing estate failed strict and resumable review — rebuilding from seed"
fi
rm -rf "$estate_dir"

echo "smoke: building specimen (window ${window}s): $*"
"$@" &
build_pid=$!
elapsed=0
while kill -0 $build_pid 2>/dev/null && (( elapsed < window )); do
  sleep 5; (( elapsed += 5 ))
done

partial=""
if kill -0 $build_pid 2>/dev/null; then
  echo "smoke: window expired — stopping the probe build"
  # Stop THIS build's whole process tree, deepest first (the tree is
  # make -> sh -> python driver -> serve, four levels). Only descendants
  # of our own build pid are touched — never serves by name.
  kill_tree() {
    local p
    for p in $(pgrep -P $1 2>/dev/null); do kill_tree $p; done
    kill $1 2>/dev/null
  }
  kill_tree $build_pid
  sleep 2
  partial="--partial"
else
  wait $build_pid
  rc=$?
  if (( rc != 0 )); then
    echo "smoke RED: build command failed (exit $rc) before the window closed"
    exit 1
  fi
  echo "smoke: build completed inside the window — strict verify, specimen kept"
fi

python3 "$here/smoke_verify.py" --seed "$seed" --estate-dir "$estate_dir" \
  ${partial:+$partial} "${verify_args[@]}"
rc=$?

if (( rc == 0 )); then
  touch "$stamp"
  if [[ -n "$partial" ]]; then
    echo "smoke: probe specimen GREEN — deleting it (strict-append import is not resumable)"
    rm -rf "$estate_dir"
  fi
  echo "smoke GATE OPEN: $stamp"
else
  echo "smoke GATE CLOSED — fix the RED checks; the full build will refuse to run"
fi
exit $rc
