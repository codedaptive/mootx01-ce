#!/bin/bash
# sign-retry.sh — run a codesign/productsign command, retrying transient
# Apple timestamp-service (TSA) failures.
#
# codesign with --timestamp (and productsign always) contact Apple's
# timestamp service during signing. The TSA is an external dependency that
# blips: candidate run 28985637069 (2026-07-09) lost its whole macOS arm64
# leg to a single "The timestamp service is not available" moments after
# the x86_64 leg signed fine on the same path. Three attempts with 10s/20s
# backoff turn that blip into seconds; a real signing problem (bad
# identity, locked keychain, missing cert) still fails on every attempt
# and surfaces within ~30s.
#
# Usage: sign-retry.sh <codesign|productsign> [args...]
# Exit: 0 on the first successful attempt; the command's failure exit
# code semantics collapse to 1 after the third failed attempt.
set -uo pipefail

for attempt in 1 2 3; do
  "$@" && exit 0
  if [ "$attempt" -lt 3 ]; then
    echo "sign-retry: attempt $attempt failed — retrying in $((attempt * 10))s: $1" >&2
    sleep $((attempt * 10))
  fi
done
echo "sign-retry: giving up after 3 attempts: $*" >&2
exit 1
