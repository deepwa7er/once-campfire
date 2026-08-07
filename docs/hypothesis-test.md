# Campfire hypothesis test — is SQLite the bottleneck?

Branch: `once-campfire-perf` (local fork at `~/code/once-campfire-perf`, copied from `basecamp/once-campfire` main).

## Hypothesis
Phase 1 knee at 100→200 (fanout 0.7s→23s, post 1.3s→20s, CPU 467%→585% / 800% = 8 cores, WAL pinned 8.1MB) is queueing behind SQLite's single writer + Redis per-member broadcast, not hardware or Wi-Fi.

## Changes in this branch (all behind flags, stock preserved when off)

**1. Cheap pragmas — `config/database.yml` `performance.variables`:**
- `cache_size: -64000` (64MB vs stock 2000=8MB)
- `wal_autocheckpoint: 4000` (vs 1000=4MB)
- `busy_timeout: 5000` (vs 0)
- `journal_mode: wal`, `synchronous: normal`, `temp_store: memory`
Effect: larger page cache, fewer checkpoints, wait instead of SQLITE_BUSY. Tests H1 without code.

**2. Batched unread — `app/models/room.rb#unread_memberships`:**
- When `CAMPFIRE_BATCH_UNREAD=1`, only `UPDATE` rows where `unread_at IS NULL OR unread_at < 5.seconds.ago`.
- Hot room at 5 posts/s goes from 5 writes/s/row → ~1/5s/row. Minimal reversible patch; full lazy-unread (single stream) is next if this moves the knee.
- Env off → stock `update_all` unchanged.

**3. Coalesced broadcast — `app/models/message/broadcasts.rb#broadcast_unread_room`:**
- When `CAMPFIRE_COALESCE_BROADCAST=1`, broadcast once to `unread_room:#{room.id}` instead of plucking 10k user_ids and broadcasting N times to `UnreadRoomsChannel`.
- Off → stock per-user loop unchanged.

## How to test on `laptop` (fedora-1)

```sh
# Build the forked image for the performance instance only
ssh laptop 'bash -lc "cd ~/code/once-campfire-perf && docker build -t campfire:perf-pragma ."'
# Or via once: once deploy campfire:perf-pragma --env performance --host 100.100.110.47

# Baseline (flags off, stock behaviour, but with new image)
ssh laptop 'bash -lc "CAMPFIRE_BATCH_UNREAD=0 CAMPFIRE_COALESCE_BROADCAST=0 docker run --rm -p 127.0.0.1:8103:80 -v once-app-once-campfire.ee2a3e:/storage campfire:perf-pragma"'

# Pragmas only (variables are already in DB config for performance env)
# → run campfire-stress: PEOPLE=100,200 against hot 10k room

# Batched + coalesced
CAMPFIRE_BATCH_UNREAD=1 CAMPFIRE_COALESCE_BROADCAST=1 bin/run.sh scenarios/chat.js  # PEOPLE=100,200
# Compare fanout p95, post p95, server.csv cpu_pct / wal_bytes / db_bytes
# Expected: pragmas shave edge; batching+coalescing should flatten 100→200 if writer is ceiling.
```

Revert: redeploy stock `ghcr.io/basecamp/once-campfire:1.4.9` to `ee2a3e` volume — no data loss (same `/storage` layout). Production container `1c9ee2` untouched.
