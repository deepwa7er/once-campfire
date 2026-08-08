# Campfire performance branch — what is here and why

Branch: `variant/perf-pragma` on `deepwa7er/once-campfire`, measured by
[campfire-stress](https://github.com/deepwa7er/campfire-stress) and read in
[readout](https://github.com/deepwa7er/readout).

Two changes remain, and both keep every feature working. A third was removed —
see the last section, because it is the most useful thing on this page.

## 1. SQLite pragmas — `config/database.yml`, `performance` only

| | stock | here |
|---|---|---|
| `cache_size` | 2000 pages (~8 MB) | **-64000 (64 MB)** |
| `wal_autocheckpoint` | 1000 pages | **4000** |
| `busy_timeout` | already 5 s via `timeout:` | 5000, stated explicitly |
| `journal_mode` / `synchronous` / `temp_store` | wal / normal / default | wal / normal / **memory** |

The database is about 20 MB at 700 employees, so an 8 MB page cache cannot hold
it and a 64 MB one can. That is the change worth measuring; the rest are either
Rails' defaults restated or already covered by `timeout:`.

**This block did nothing for its first three weeks.** It was keyed `variables:`,
which is the MySQL and Postgres convention — the SQLite adapter reads `pragmas:`
and ignores keys it does not recognise, so nothing failed and nothing applied.
Every measurement labelled "tuned" before 2026-08-08 was taken against stock
SQLite settings. If a result from that period is cited anywhere, it is a result
about the application changes below and not about SQLite at all.

## 2. Batched unread — `app/models/room.rb`

Behind `CAMPFIRE_BATCH_UNREAD=1`. Stock rewrites every disconnected member's
membership row on every post; this skips rows already marked unread within the
last five seconds.

**No feature changes.** `unread_at` is read as a boolean everywhere it is used
(`unread?` is `unread_at.present?`, and the sidebar scope is
`where.not(unread_at: nil)`), so a row that is already showing a badge does not
need the newer timestamp. A membership that has been *read* has `unread_at` of
NULL and is therefore always re-marked — the badge still lights.

What it saves is write volume, and with it time holding SQLite's single writer,
which every other write in the app queues behind.

## 3. Coalesced broadcast — REMOVED, and worth understanding

This branch used to publish one broadcast per room instead of one per member:

```ruby
ActionCable.server.broadcast "unread_room:#{room.id}", { roomId: room.id }
```

It was the fastest change here by a distance — in a 700-employee company it took
posting from a p95 of 1,211 ms to 158 ms and cut server CPU by a fifth.

It also broke the unread badge. Clients subscribe through `UnreadRoomsChannel`,
which streams from `user_<id>_unreads`; nothing subscribes to `unread_room:<id>`,
so the notification went nowhere. A real user's sidebar would simply stop
lighting up for rooms they were not looking at.

The load test could not see that. It subscribes to `UnreadRoomsChannel` with an
empty callback and asserts nothing arrives, so a server that stopped sending
unread notifications measured as a server that had got faster. **A benchmark
only measures the work you make it check for.**

Two ways to have the win without removing the feature, neither yet measured:

- **Pipeline the publishes.** 700 sequential Redis round trips inside the
  poster's request become one batched write. Same semantics.
- **Move them off the request.** `messages_controller#create` calls
  `broadcast_create` directly, so the poster waits for the whole fan-out. A
  background job does the same work without the poster paying for it.
