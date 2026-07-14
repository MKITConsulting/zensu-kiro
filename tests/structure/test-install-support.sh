#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/scripts/install-support.js"
RUNTIME_LOCK="$ROOT/hooks/lib/kiro-runtime-lock.js"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
sha() { node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$1"; }
wait_for() { # file
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
  [ -e "$1" ]
}

TMP="$(mktemp -d -t zensu-install-support-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root" "$TMP/barrier"

# Arbitrarily large numeric identifiers must retain exact SemVer precedence.
printf '1.0.0-beta.9007199254740993\n' > "$TMP/root/VERSION"
printf '{"version":"1.0.0-beta.9007199254740993","files":{}}\n' > "$TMP/root/manifest.json"
OUT="$(node "$HELPER" preflight "$TMP/root/manifest.json" "$TMP/root/VERSION" \
  '1.0.0-beta.9007199254740992' "$TMP/root" "$TMP" 0 2>&1)"; RC=$?
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q downgrade; then
  ok "large SemVer prerelease identifiers compare exactly"
else
  bad "large SemVer identifiers lost precedence (rc=$RC: $OUT)"
fi

# The expected hash is rechecked after the helper has prepared its temporary
# replacement. A deterministic barrier lets an ordinary editor win the race.
printf 'managed\n' > "$TMP/root/write.txt"; EXPECTED="$(sha "$TMP/root/write.txt")"
rm -f "$TMP/barrier"/*
(
  printf 'replacement\n' | NODE_ENV=test ZENSU_INSTALL_TEST_BARRIER_DIR="$TMP/barrier" \
    node "$HELPER" atomic-write "$TMP/root" "$TMP/root/write.txt" "$TMP" 0 file "$EXPECTED" > "$TMP/write.out" 2>&1
) & WRITE_PID=$!
if wait_for "$TMP/barrier/atomic-write.reached"; then
  printf 'editor wins\n' > "$TMP/root/write.txt"
  : > "$TMP/barrier/atomic-write.release"
  wait "$WRITE_PID"; RC=$?
  if [ "$RC" -ne 0 ] && [ "$(cat "$TMP/root/write.txt")" = "editor wins" ]; then
    ok "atomic write refuses a concurrent editor change"
  else
    bad "atomic write overwrote a concurrent editor change"
  fi
else
  bad "atomic-write test barrier was not reached"
  kill "$WRITE_PID" 2>/dev/null || true
fi

# A process crash after claiming the old inode must leave a self-describing
# recovery artifact that the next installer can restore before preflight.
printf 'managed crash restore\n' > "$TMP/root/crash.txt"; EXPECTED="$(sha "$TMP/root/crash.txt")"
rm -f "$TMP/barrier"/* "$TMP/root/crash.txt".zensu-recovery.*
(
  printf 'installer crash replacement\n' | NODE_ENV=test ZENSU_INSTALL_TEST_BARRIER_DIR="$TMP/barrier" \
    node "$HELPER" atomic-write "$TMP/root" "$TMP/root/crash.txt" "$TMP" 0 file "$EXPECTED" > "$TMP/crash.out" 2>&1
) & CRASH_PID=$!
if wait_for "$TMP/barrier/atomic-write.reached"; then
  : > "$TMP/barrier/atomic-write.release"
  if wait_for "$TMP/barrier/atomic-write-publish.reached"; then
    kill -9 "$CRASH_PID" 2>/dev/null || true; wait "$CRASH_PID" 2>/dev/null || true
    node "$HELPER" recover-target "$TMP/root" "$TMP/root/crash.txt" "$TMP" >/dev/null 2>&1; RC=$?
    if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/root/crash.txt" 2>/dev/null)" = "managed crash restore" ] && \
       ! find "$TMP/root" -maxdepth 1 -type f -name 'crash.txt.zensu-recovery.*' | grep -q .; then
      ok "crash between claim and publication is recovered before retry"
    else
      bad "crash recovery did not restore the claimed managed file"
    fi
  else
    bad "crash recovery publication barrier was not reached"
    kill "$CRASH_PID" 2>/dev/null || true
  fi
else
  bad "crash recovery claim barrier was not reached"
  kill "$CRASH_PID" 2>/dev/null || true
fi

printf 'managed remove\n' > "$TMP/root/remove.txt"; EXPECTED="$(sha "$TMP/root/remove.txt")"
rm -f "$TMP/barrier"/*
NODE_ENV=test ZENSU_INSTALL_TEST_BARRIER_DIR="$TMP/barrier" \
  node "$HELPER" remove "$TMP/root" "$TMP/root/remove.txt" "$TMP" "$EXPECTED" > "$TMP/remove.out" 2>&1 & REMOVE_PID=$!
if wait_for "$TMP/barrier/remove.reached"; then
  printf 'editor keeps\n' > "$TMP/root/remove.txt"
  : > "$TMP/barrier/remove.release"
  wait "$REMOVE_PID"; RC=$?
  if [ "$RC" -ne 0 ] && [ "$(cat "$TMP/root/remove.txt")" = "editor keeps" ]; then
    ok "safe remove refuses a concurrent editor change"
  else
    bad "safe remove deleted a concurrent editor change"
  fi
else
  bad "remove test barrier was not reached"
  kill "$REMOVE_PID" 2>/dev/null || true
fi

# A new file appearing after a missing-state inspection must win without being
# overwritten by rename semantics.
rm -f "$TMP/root/new.txt" "$TMP/barrier"/*
(
  printf 'installer new\n' | NODE_ENV=test ZENSU_INSTALL_TEST_BARRIER_DIR="$TMP/barrier" \
    node "$HELPER" atomic-write "$TMP/root" "$TMP/root/new.txt" "$TMP" 0 missing - > "$TMP/new.out" 2>&1
) & NEW_PID=$!
if wait_for "$TMP/barrier/atomic-write.reached"; then
  printf 'editor new\n' > "$TMP/root/new.txt"
  : > "$TMP/barrier/atomic-write.release"
  wait "$NEW_PID"; RC=$?
  if [ "$RC" -ne 0 ] && [ "$(cat "$TMP/root/new.txt")" = "editor new" ]; then
    ok "missing-state publication never overwrites a newly created file"
  else
    bad "missing-state publication overwrote a concurrent create"
  fi
else
  bad "missing-state publication barrier was not reached"
  kill "$NEW_PID" 2>/dev/null || true
fi

# If an editor creates the target after the expected old inode was claimed,
# the helper preserves both the editor's file and the old bytes in quarantine.
printf 'managed publish\n' > "$TMP/root/publish.txt"; EXPECTED="$(sha "$TMP/root/publish.txt")"
rm -f "$TMP/barrier"/* "$TMP/root"/*.zensu-recovery.*
(
  printf 'installer publish\n' | NODE_ENV=test ZENSU_INSTALL_TEST_BARRIER_DIR="$TMP/barrier" \
    node "$HELPER" atomic-write "$TMP/root" "$TMP/root/publish.txt" "$TMP" 0 file "$EXPECTED" > "$TMP/publish.out" 2>&1
) & PUBLISH_PID=$!
if wait_for "$TMP/barrier/atomic-write.reached"; then
  : > "$TMP/barrier/atomic-write.release"
  if wait_for "$TMP/barrier/atomic-write-publish.reached"; then
    printf 'editor after claim\n' > "$TMP/root/publish.txt"
    : > "$TMP/barrier/atomic-write-publish.release"
    wait "$PUBLISH_PID"; RC=$?
    RECOVERY_COUNT="$(find "$TMP/root" -maxdepth 1 -type f -name '*.zensu-recovery.*' | wc -l | tr -d ' ')"
    if [ "$RC" -ne 0 ] && [ "$(cat "$TMP/root/publish.txt")" = "editor after claim" ] && [ "$RECOVERY_COUNT" -eq 1 ]; then
      ok "post-claim publication race preserves editor and recovery bytes"
    else
      bad "post-claim publication race lost editor or recovery bytes"
    fi
    rm -f "$TMP/root"/*.zensu-recovery.*
  else
    bad "post-claim publication barrier was not reached"
    kill "$PUBLISH_PID" 2>/dev/null || true
  fi
else
  bad "claim barrier was not reached"
  kill "$PUBLISH_PID" 2>/dev/null || true
fi

# Lock ownership uses a random token, rejects active contenders, recovers dead
# owners, and leaves no partial directory when owner publication fails.
LOCK="$TMP/.install.lock"
TOKEN="$(node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "${#TOKEN}" -eq 64 ]; then ok "lock publishes token-bound owner metadata"; else bad "lock acquisition failed: $TOKEN"; fi
node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 75 ] && ok "live lock owner blocks a contender" || bad "live lock was recovered or misclassified (rc=$RC)"
node "$HELPER" release-lock "$TMP" "$LOCK" "$$" "$(printf '0%.0s' {1..64})" >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && [ -f "$LOCK" ] && [ ! -L "$LOCK" ] && ok "wrong token cannot release a lock" || bad "wrong token released a lock"
node "$HELPER" release-lock "$TMP" "$LOCK" "$$" "$TOKEN" >/dev/null 2>&1

# Recovery is serialized: a slow contender that observed a stale lock cannot
# later quarantine the live lock published by the winning contender.
( : ) & DEAD_PID=$!; wait "$DEAD_PID"
node "$HELPER" acquire-lock "$TMP" "$LOCK" "$DEAD_PID" >/dev/null 2>&1
rm -f "$TMP/barrier"/*
NODE_ENV=test ZENSU_INSTALL_TEST_BARRIER_DIR="$TMP/barrier" \
  node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" > "$TMP/slow-lock.out" 2>&1 & SLOW_LOCK_PID=$!
if wait_for "$TMP/barrier/lock-recovery-snapshot.reached"; then
  FAST_TOKEN="$(node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" 2>&1)"; FAST_RC=$?
  : > "$TMP/barrier/lock-recovery-snapshot.release"
  wait "$SLOW_LOCK_PID"; SLOW_RC=$?
  if [ "$FAST_RC" -eq 0 ] && [ "$SLOW_RC" -eq 75 ] && [ -f "$LOCK" ] && \
     node "$HELPER" release-lock "$TMP" "$LOCK" "$$" "$FAST_TOKEN" >/dev/null 2>&1; then
    ok "stale recovery never displaces a newly published live lock"
  else
    bad "stale recovery displaced or invalidated the winning live lock"
  fi
else
  bad "lock recovery snapshot barrier was not reached"
  kill "$SLOW_LOCK_PID" 2>/dev/null || true
  wait "$SLOW_LOCK_PID" 2>/dev/null || true
  rm -rf "$LOCK" "$LOCK.recovery"
fi

( : ) & DEAD_PID=$!; wait "$DEAD_PID"
node "$HELPER" acquire-lock "$TMP" "$LOCK" "$DEAD_PID" >/dev/null 2>&1
TOKEN="$(node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "dead-owner lock is recovered"
  node "$HELPER" release-lock "$TMP" "$LOCK" "$$" "$TOKEN" >/dev/null 2>&1
else
  bad "dead-owner lock was not recovered: $TOKEN"
fi

# Recovery-guard reclamation is itself crash-safe. A dead guard and a dead
# unique claimant are reclaimed, while a live claim remains first-class busy
# protocol state for every third contender.
( : ) & DEAD_PID=$!; wait "$DEAD_PID"
node "$HELPER" acquire-lock "$TMP" "$LOCK" "$DEAD_PID" >/dev/null 2>&1
GUARD_TOKEN="$(printf 'c%.0s' {1..64})"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$DEAD_PID" "$GUARD_TOKEN" > "$LOCK.recovery"
CLAIM_TOKEN="$(printf 'd%.0s' {1..64})"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z","targetFingerprint":"orphan"}\n' \
  "$DEAD_PID" "$CLAIM_TOKEN" > "$LOCK.recovery.reclaim.$CLAIM_TOKEN"
TOKEN="$(node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$LOCK.recovery" ] && \
   ! find "$TMP" -maxdepth 1 -name '.install.lock.recovery.reclaim.*' | grep -q .; then
  ok "crash-stranded recovery guard and claimant are recovered"
  node "$HELPER" release-lock "$TMP" "$LOCK" "$$" "$TOKEN" >/dev/null 2>&1
else
  bad "crash-stranded recovery protocol state blocked forever: $TOKEN"
  rm -f "$LOCK" "$LOCK.recovery" "$LOCK.recovery.reclaim."*
fi

# Many retrying processes may enumerate the same orphan claims before any one
# of them removes those unique files. Disappearing claims are a benign cleanup
# race: exactly one contender acquires the recovered main lock, every loser is
# retryable-busy (75), and no contender reports an internal rc=3 failure.
( : ) & DEAD_PID=$!; wait "$DEAD_PID"
node "$HELPER" acquire-lock "$TMP" "$LOCK" "$DEAD_PID" >/dev/null 2>&1
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$DEAD_PID" "$GUARD_TOKEN" > "$LOCK.recovery"
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  CLAIM_TOKEN="$(printf '%064x' "$n")"
  printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z","targetFingerprint":"orphan-%s"}\n' \
    "$DEAD_PID" "$CLAIM_TOKEN" "$n" > "$LOCK.recovery.reclaim.$CLAIM_TOKEN"
done
CONCURRENT_START="$TMP/concurrent-orphan-start"
CONCURRENT_PIDS=""
for n in 1 2 3 4 5 6 7 8; do
  (
    while [ ! -e "$CONCURRENT_START" ]; do sleep 0.01; done
    node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" > "$TMP/concurrent-orphan-$n.out" 2>&1
    printf '%s\n' "$?" > "$TMP/concurrent-orphan-$n.rc"
  ) &
  CONCURRENT_PIDS="$CONCURRENT_PIDS $!"
done
: > "$CONCURRENT_START"
for pid in $CONCURRENT_PIDS; do wait "$pid" 2>/dev/null || true; done
CONCURRENT_WINNERS=0; CONCURRENT_BUSY=0; CONCURRENT_OTHER=0; WINNER_TOKEN=""
for n in 1 2 3 4 5 6 7 8; do
  RC="$(cat "$TMP/concurrent-orphan-$n.rc" 2>/dev/null || printf missing)"
  case "$RC" in
    0) CONCURRENT_WINNERS=$((CONCURRENT_WINNERS + 1)); WINNER_TOKEN="$(cat "$TMP/concurrent-orphan-$n.out")" ;;
    75) CONCURRENT_BUSY=$((CONCURRENT_BUSY + 1)) ;;
    *) CONCURRENT_OTHER=$((CONCURRENT_OTHER + 1)) ;;
  esac
done
EVENTUAL_OK=0
if [ "$CONCURRENT_OTHER" -eq 0 ] && [ "$CONCURRENT_WINNERS" -le 1 ] && \
   [ $((CONCURRENT_WINNERS + CONCURRENT_BUSY)) -eq 8 ]; then
  if [ "$CONCURRENT_WINNERS" -eq 1 ]; then
    node "$HELPER" release-lock "$TMP" "$LOCK" "$$" "$WINNER_TOKEN" >/dev/null 2>&1 && EVENTUAL_OK=1
  else
    # A simultaneous election may conservatively return busy to every
    # participant. The installer's normal retry must then recover immediately
    # without a fatal rc=3 or stranded claim.
    WINNER_TOKEN="$(node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" 2>/dev/null)"; RC=$?
    [ "$RC" -eq 0 ] && node "$HELPER" release-lock "$TMP" "$LOCK" "$$" "$WINNER_TOKEN" >/dev/null 2>&1 && EVENTUAL_OK=1
  fi
fi
if [ "$EVENTUAL_OK" -eq 1 ] && [ ! -e "$LOCK.recovery" ] && \
   ! find "$TMP" -maxdepth 1 -name '.install.lock.recovery.reclaim.*' | grep -q .; then
  ok "concurrent orphan-claim cleanup is retryable and converges without fatal errors"
else
  bad "concurrent orphan cleanup produced a fatal race (win=$CONCURRENT_WINNERS busy=$CONCURRENT_BUSY other=$CONCURRENT_OTHER)"
  rm -f "$LOCK" "$LOCK.recovery" "$LOCK.recovery.reclaim."*
fi

LIVE_CLAIM_TOKEN="$(printf 'e%.0s' {1..64})"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z","targetFingerprint":"live-election"}\n' \
  "$$" "$LIVE_CLAIM_TOKEN" > "$LOCK.recovery.reclaim.$LIVE_CLAIM_TOKEN"
node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 75 ] && [ -f "$LOCK.recovery.reclaim.$LIVE_CLAIM_TOKEN" ]; then
  ok "live recovery claim is visible as busy to a third contender"
else
  bad "third contender ignored or deleted a live recovery claim (rc=$RC)"
fi
rm -f "$LOCK.recovery.reclaim.$LIVE_CLAIM_TOKEN"

# A contender paused after observing a stale guard must never move or delete a
# replacement live guard. The unique election claim stays visible throughout.
( : ) & DEAD_PID=$!; wait "$DEAD_PID"
node "$HELPER" acquire-lock "$TMP" "$LOCK" "$DEAD_PID" >/dev/null 2>&1
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$DEAD_PID" "$GUARD_TOKEN" > "$LOCK.recovery"
rm -f "$TMP/barrier"/*
NODE_ENV=test ZENSU_INSTALL_TEST_BARRIER_DIR="$TMP/barrier" \
  node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" > "$TMP/guard-race.out" 2>&1 & GUARD_RACE_PID=$!
if wait_for "$TMP/barrier/recovery-claim-published.reached"; then
  CLAIM_COUNT="$(find "$TMP" -maxdepth 1 -type f -name '.install.lock.recovery.reclaim.*' | wc -l | tr -d ' ')"
  LIVE_GUARD_TOKEN="$(printf 'f%.0s' {1..64})"
  rm -f "$LOCK.recovery"
  printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
    "$$" "$LIVE_GUARD_TOKEN" > "$LOCK.recovery"
  node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" >/dev/null 2>&1; THIRD_RC=$?
  : > "$TMP/barrier/recovery-claim-published.release"
  wait "$GUARD_RACE_PID"; GUARD_RACE_RC=$?
  LIVE_BYTES="$(cat "$LOCK.recovery" 2>/dev/null)"
  if [ "$CLAIM_COUNT" -eq 1 ] && [ "$THIRD_RC" -eq 75 ] && [ "$GUARD_RACE_RC" -eq 75 ] && \
     printf '%s' "$LIVE_BYTES" | grep -q "$LIVE_GUARD_TOKEN" && \
     ! find "$TMP" -maxdepth 1 -type f -name '.install.lock.recovery.reclaim.*' | grep -q .; then
    ok "stale snapshot election preserves a replacement live recovery guard"
  else
    bad "stale snapshot claimant hid, moved, or deleted replacement protocol state"
  fi
else
  bad "recovery claim publication barrier was not reached"
  kill "$GUARD_RACE_PID" 2>/dev/null || true
  wait "$GUARD_RACE_PID" 2>/dev/null || true
fi
rm -f "$LOCK" "$LOCK.recovery" "$LOCK.recovery.reclaim."*

# Upgrade compatibility: recover the previous directory-lock format only when
# its token-bound owner is provably dead.
mkdir "$LOCK"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$DEAD_PID" "$(printf 'a%.0s' {1..64})" > "$LOCK/owner.json"
TOKEN="$(node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$LOCK" ]; then
  ok "dead owner in the legacy directory-lock format is recovered"
  node "$HELPER" release-lock "$TMP" "$LOCK" "$$" "$TOKEN" >/dev/null 2>&1
else
  bad "dead legacy directory lock was not recovered"
fi

mkdir "$LOCK"
node -e 'const fs=require("fs");const d=new Date(Date.now()-120000);fs.utimesSync(process.argv[1],d,d)' "$LOCK"
TOKEN="$(node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "legacy ownerless lock is recovered after conservative grace period"
  node "$HELPER" release-lock "$TMP" "$LOCK" "$$" "$TOKEN" >/dev/null 2>&1
else
  bad "old ownerless lock was not recovered: $TOKEN"
fi

NODE_ENV=test ZENSU_INSTALL_TEST_FAIL_OWNER_WRITE=1 node "$HELPER" acquire-lock "$TMP" "$LOCK" "$$" >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && [ ! -e "$LOCK" ] && ok "owner-write failure never publishes a partial lock" || bad "owner-write failure stranded a lock"

DIRECT_LOCK="$TMP/.runtime-direct.lock"
DIRECT_TOKEN="$(node "$RUNTIME_LOCK" acquire "$TMP" "$DIRECT_LOCK" "$$" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$DIRECT_LOCK" ] && \
   node "$RUNTIME_LOCK" release "$TMP" "$DIRECT_LOCK" "$$" "$DIRECT_TOKEN" >/dev/null 2>&1; then
  ok "installed runtime lock CLI shares the installer ownership protocol"
else
  bad "runtime lock CLI could not acquire and release its direct lock"
fi
node "$RUNTIME_LOCK" not-a-command >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && ok "runtime lock CLI rejects unknown commands" || bad "runtime lock CLI accepted an unknown command"

# Quote/backslash handling is tested directly, without requiring characters
# that NTFS forbids in a real HOME directory.
printf '{"hooks":{"x":[{"command":"bash \\\"__ZENSU_HOME__/hook.sh\\\""}]}}\n' > "$TMP/agent.json"
HOSTILE='C:\path with space\" and $dollar `tick`'
RENDERED="$(node "$HELPER" render-json "$TMP/agent.json" "$HOSTILE" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && RENDERED="$RENDERED" HOSTILE="$HOSTILE" node -e '
  const j=JSON.parse(process.env.RENDERED); const c=j.hooks.x[0].command;
  if (!c.includes("\\\\") || !c.includes("\\\"") || !c.includes("\\$") || !c.includes("\\`")) process.exit(1);
'; then
  ok "render-json escapes quote, backslash, dollar, and backtick structurally"
else
  bad "render-json mishandled shell metacharacters (rc=$RC)"
fi

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
