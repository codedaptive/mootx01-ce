---
version: v0.1
wave: CORE-09 (Community 1.1 Core, Wave E1)
scope: Automated subset complete; physical scenarios enumerated below.
last-updated: 2026-08-25
---

# CORE-09: Physical Evidence Ledger

This file enumerates every CORE-09 acceptance scenario that requires a live
launchd environment and therefore cannot be verified by automated test.
Automated coverage (32 tests across MootInstallerCoreTests and
MootDaemonProviderTests) is complete for all scenarios that do NOT require
process spawn, launchctl ceremony, or a running launchd.

---

## Automated coverage (for reference)

These scenarios are verified by the automated test suite and do NOT
appear in the physical ledger below.

- Enabled plist content contract (RunAtLoad=true, KeepAlive=true, correct
  label, correct ProgramArguments, well-formed XML)
- Enabled install readback: service identity + executable path round-trip
- Typed blocked state: missing plist, plist content mismatch, missing
  executable, non-executable file
- Removal report: daemonConfiguration and estateData preservation distinction
- SIGKILL simulation: ProviderLock release + re-acquisition; generation store
  custody preserved across restart
- Upgrade serialization: GenerationStore generation fence prevents two
  concurrent writers; rollback refused; stale proof invalidated on lock release
- Census: exactly one lock holder at every transition boundary (EWOULDBLOCK
  confirms no orphaned lock)
- DaemonProvider race: exactly one actor-level winner; loser performs zero
  side-effect callbacks

---

## Physical scenarios (require real launchd, real process, or real login session)

### P-01: launchctl bootstrap — daemon registered after bootstrap

**CORE-09 claim:** Installation reports success only when the expected service
identity and executable are registered.

**Why physical:** `launchctl bootstrap gui/<uid> <plist>` writes the service
into the launchd session database. `assessDaemonBundleInstallation` validates
the plist on disk and the executable path; it cannot observe the launchd
registration state. Confirming that the label appears in
`launchctl print gui/<uid>` and that the executable path matches the contract
requires a live launchd session.

**Manual procedure:**
1. Run `install` subcommand: `./mootx01 install`.
2. Confirm exit 0.
3. `launchctl print gui/$(id -u) | grep com.codedaptive.mootx01.daemon` — label
   must appear with `state = running` or `state = waiting`.
4. `launchctl print gui/$(id -u)/com.codedaptive.mootx01.daemon | grep path` —
   must equal the bundle executable URL from `DaemonBundle.bundleExecutableURL`.

---

### P-02: Readiness vs launch — distinguishable from mere process launch

**CORE-09 claim:** Readiness is distinguishable from mere process launch.

**Why physical:** Readiness is the moment the daemon atomically publishes its
`FirstPartyDescriptor` beside the App Group provider directory after lock,
estate, and loopback-bind proofs have all succeeded. The descriptor names the
authenticated first-party HTTP route. It is not itself exposed through an
unauthenticated HTTP GET endpoint.

**Manual procedure:**
1. After `launchctl bootstrap` (P-01), immediately poll the signed provider's
   App Group descriptor file:
   `~/Library/Group Containers/<team>.group.com.codedaptive.mootx01/Library/Application Support/MOOTx01/daemon-descriptor.v2.json`.
2. The first complete, parseable descriptor is readiness. Record the process
   PID before the descriptor appears so process launch and readiness remain
   distinguishable observations.
3. Confirm the descriptor JSON contains `estateIdentifier`, `binaryVersion`,
   `capabilities`, and the endpoint
   `http://127.0.0.1:4242/mcp/first-party`.
4. Exercise that route with the first-party authenticated handshake. A plain
   unauthenticated GET may refuse or return 404 and is not a readiness probe.
5. Record process-start and descriptor-publication timestamps in the physical
   evidence packet. The provider stdout log is
   `~/.mootx01/logs/mootx01-provider.out.log`.

---

### P-03: Unexpected exit and restart — restart policy preserves estate custody

**CORE-09 claim:** Unexpected exit follows the documented restart policy and
preserves estate custody.

**Why physical:** The `KeepAlive=true` key in the plist instructs launchd to
restart the daemon when it exits unexpectedly. Automated tests prove that the
ProviderLock is released on process termination (fd close by kernel) and that
a new provider instance can re-acquire it; they cannot prove that launchd
actually performs the restart or that the restarted instance opens the SAME
estate database.

**Manual procedure:**
1. With the daemon running (P-02 complete), note the current PID:
   `launchctl print gui/$(id -u)/com.codedaptive.mootx01.daemon | grep pid`.
2. Kill the process: `kill -KILL <pid>`.
3. Wait 3 seconds. launchd respawn rate-limiting may impose a brief delay.
4. Confirm a new PID is running:
   `launchctl print gui/$(id -u)/com.codedaptive.mootx01.daemon | grep pid`.
5. Poll the descriptor endpoint (P-02 procedure) — the descriptor must return
   the SAME `estateIdentifier` UUID as before the kill (same estate, not a
   new one).
6. Inspect `~/Library/Logs/mootx01-provider.out.log` — the restart log line
   must reference the same estate path.

---

### P-04: Upgrade — no concurrent old and new writers

**CORE-09 claim:** Upgrade never creates concurrent old and new writers.

**Why physical:** The GenerationStore fence is proven by automated test. The
physical claim requires an actual upgrade: the installer runs while the old
daemon is running, the old daemon exits (or is signaled to exit), and the new
binary takes over. The flock-based serialization must prevent the new binary
from activating before the old fd is closed.

**Manual procedure:**
1. With the daemon running at version N, copy version N+1 binary into the
   bundle (or run `mootx01 upgrade` if the upgrade path is wired).
2. Observe via `launchctl print` that only one PID is live at all times.
3. Inspect the generation store file
   (`~/Library/Group Containers/<group>/mootx01/daemon/generations.v1`) before
   and after: `provider` counter must increase by exactly 1, never reset.
4. Confirm no "lock unavailable" error in logs from the new binary — it must
   acquire on first attempt (old binary has released before new binary runs).

---

### P-05: Login launch — daemon starts automatically at next login

**CORE-09 claim:** Installation reports success (implied: at login the daemon
is live).

**Why physical:** `RunAtLoad=true` in the plist triggers launch at bootstrap
time. Verifying that a fresh login session starts the daemon requires a
logout/login cycle.

**Manual procedure:**
1. After installation (P-01), log out of the macOS account.
2. Log back in.
3. Within 10 seconds, poll `http://127.0.0.1:4242/mcp-first-party-descriptor`.
4. A successful response confirms the daemon started automatically at login.
5. Check `launchctl print gui/$(id -u)/com.codedaptive.mootx01.daemon` to
   confirm `state = running`.

---

### P-06: Removal — report shows whether config and estate are retained or removed

**CORE-09 claim:** Removal reports whether daemon configuration and estate data
are retained or removed.

**Why physical:** `reportUninstallPreservation` is tested for filesystem
presence. A real removal must also call `launchctl bootout` to unregister the
service before (or after) removing the plist. The physical test confirms that
the removal sequence is correct: bootout before plist removal, and that the
estate database is retained (unless explicitly opted out).

**Manual procedure:**
1. With the daemon running, run `mootx01 uninstall --yes` with no `--target`
   and without `--purge`. Estate retention is the default; there is no
   `--keep-estate` option.
2. Confirm exit 0 and output includes removal of the management console,
   resident daemon, and Community provider plus the explicit statement that
   estate data, migration receipts, backups, and Keychain credentials are
   preserved.
3. Confirm `launchctl print gui/$(id -u) | grep com.codedaptive.mootx01.daemon`
   returns empty (service unregistered).
4. Confirm `~/Library/LaunchAgents/com.codedaptive.mootx01.daemon.plist` is
   absent.
5. Confirm `~/Library/Group Containers/<group>/mootx01/estate.sqlite` is
   present.

---

### P-07: Blocked state — broken or incompatible installation produces typed blocked state

**CORE-09 claim:** A broken or incompatible installation produces a typed
blocked state for the application.

**Why physical:** `assessDaemonBundleInstallation` returns typed blocked reasons
from the filesystem. The physical test confirms that the app surface renders the
correct blocked state to the user when the assessment returns `.blocked(reason:)`
— which requires a running app connected to the assessment API.

**Manual procedure:**
1. Remove the daemon executable from the bundle without unregistering:
   `rm ~/Applications/Mootx01DaemonProvider.app/Contents/MacOS/Mootx01DaemonProvider`.
2. Open the mootx01 app.
3. Confirm the UI displays a blocked state describing a missing executable
   (corresponding to `.blocked(.missingExecutable)`).
4. Restore the executable and confirm the blocked state clears.

---

### P-08: Community and Pro cross-install ownership policy

**CORE-09 claim:** Community and Pro installations follow the defined
cross-install ownership policy.

**Why physical:** The cross-install policy (which installation wins the flock)
requires two real app bundles to be installed and running concurrently. The
flock serialization is proven by automated test; the policy routing (which
descriptor wins) requires the Pro-overrides-Community path to be exercised with
real entitlements.

**Manual procedure:**
1. Install Community edition daemon.
2. Install Pro edition daemon alongside it.
3. Observe that only one PID holds the lock (use `lsof` on the lock file).
4. Confirm the descriptor endpoint returns the Pro descriptor (higher authority
   wins per the policy).
5. Remove Pro; confirm Community re-activates automatically (launchd restart
   path, P-03).

---

## Record

| Scenario | Status |
|---|---|
| P-01: launchctl bootstrap | PASS 2026-08-25 — install exit 0; expected label, bundle executable, and running PID observed |
| P-02: Readiness vs launch | RERUN REQUIRED — 2026-08-25 exposed and corrected a stale nonexistent HTTP descriptor URL |
| P-03: Unexpected exit / restart | PASS 2026-08-25 — SIGKILL produced a new PID with the same estate identifier and rebound port 4242 |
| P-04: Upgrade (no concurrent writers) | Physical — requires two binary versions |
| P-05: Login launch | Physical — requires logout/login cycle |
| P-06: Removal report | RERUN REQUIRED — 2026-08-25 exposed and corrected the nonexistent `--keep-estate` option |
| P-07: Blocked state app surface | Physical — requires running app |
| P-08: Community/Pro cross-install | Physical — requires two editions |

Automated coverage: 32 tests (CORE-09 automated subset). Physical record: 8 scenarios.
