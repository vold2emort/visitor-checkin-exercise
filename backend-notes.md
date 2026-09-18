# Backend Track Notes

Three server-side defects were fixed.

## Defect mapping

The three fixed defects are:

| Defect | What it is |
|--------|-----------|
| Defect 1 | Deactivated users are still surfaced - in the **active list** and in the **repeat-visit search** |
| Defect 2 | API accepts empty/incomplete visitor records (**no server-side validation**) **and** records/serializes check-in timestamps in **UTC instead of Asia/Kathmandu** |
| Defect 3 | **N+1 query load** when rendering the active list |

## Fixed defects and their request specs

All request specs live in `api/test/requests/visitors_request_test.rb`. 

| Defect | Fix | Request spec | On original `main` | On updated code |
|--------|-----|--------------|--------------------|-----------------|
| 1 | `GET /api/visitors` now filters `active: true` **and** `GET /api/visitors/search` now filters `active: true` (checked-out visitors stay selectable for legitimate repeat visits) | "deactivated visitors are not returned by the active list or repeat-visit search" | FAIL - deactivated `Sam Inactive` returned by active list | PASS |
|  2 | `Visitor` model now requires `full_name`, `company_name`, `purpose`, and `host` (presence validations; `create` already renders `422` when `save` fails), rejects a `host_id` that does not reference an existing host (explicit `host_id` existence check with a dedicated error), **and** `config.time_zone = "Asia/Kathmandu"` so check-in/check-out timestamps are created and serialized as `+05:45` instead of `Z` (UTC) | "POST /api/visitors validates required fields and records check-in in Kathmandu time" | FAIL — empty/missing-field POST saved a record (201), an unknown `host_id` was accepted with a dangling FK, and timestamps serialized with `Z` (offset 0) | PASS (422 / no row created for empty, missing-field, or unknown-host `host_id` with `"host_id": ["must reference an existing host"]`; valid POST returns `checked_in_at` with `utc_offset` `+05:45`) |
| 3 | `GET /api/visitors` now eager loads hosts with `.includes(:host)` | "GET /api/visitors eager loads hosts instead of issuing an N+1" | FAIL - 21 SQL statements | PASS (2) |

The pre-existing controller test `POST /api/visitors with empty body creates a record`
asserted the buggy behavior and was necessarily updated - the intended behavior changed, so
the test now asserts `422` and that no record is created.

**API response structure/value change:** the Defect 2 fix intentionally changes the API
contract in two ways.
1. Invalid/incomplete `POST /api/visitors` requests that previously returned
   `201 Created` (with a persisted record) now return `422 Unprocessable Entity` with
   `{ "errors": { ... } }`. The rejected cases cover empty/incomplete bodies **and** a
   `host_id` that does not exist — that last one returns the specific error
   `{ "errors": { "host_id": ["must reference an existing host"] } }` rather than the
   generic association message.
2. Valid timestamps change representation: `checked_in_at` / `checked_out_at` are now
   serialized with the `Asia/Kathmandu` offset (`...+05:45`) instead of UTC (`...Z`). The
   underlying instant stored in the database is unchanged, Rails still stores UTC instants
   (`config.active_record.default_timezone` untouched), so no existing data needs
   migrating; existing rows are simply read back and rendered in Kathmandu time.

These are deliberate, spec-driven changes. The web client currently marks only `full_name`
and `host_id` as required and shows no error feedback on a failed POST, so a frontend fix follow-up is needed for the remaining fields(not fixed due to backend track).

## Why these three defects were selected

1. **Defect 1 (deactivated visitors surfaced)**: a direct, explicit violation of the spec in
   both places it is stated: "Deactivated visitors must not appear in the active list" and
   "must not be selectable when registering a repeat visit.". High functional
   impact (an admin deactivates a record and it stays on the front-desk list / can be booked
   again) and easy to miss, the seed data happens to give every seeded deactivated visitor a
   `checked_out_at` timestamp, so development data masks the bug.
2. **Defect 2 (no server-side validation + UTC timestamps)**: It is never good for backend to rely that the frontend will send correct data so I choose server side validation, targeted two server-side gaps that both
   contradict the spec. (a) The spec requires a full name, company, host, and purpose on every
   registration, but the API happily persisted empty rows; fixing it enforces the registration
   contract . (b) The app is
   explicitly designed for the Asia/Kathmandu timezone (the seed data even computes two
   visitors against the Kathmandu offset, db/seeds.rb:48) and the README requires times in the
   receptionist's local timezone, yet no `config.time_zone` was set, so every check-in was
   recorded and serialized as UTC. The fix makes the server run in Kathmandu time end-to-end.
   Combined, this was the one fix that changes the API surface (201 → 422) and the timestamp
   value (`Z` → `+05:45`), so both are deliberately called out above.
3. **Defect 3 (N+1)** — the only performance-type defect in the codebase, and the brief
   requires that if a performance defect is found, one fix addresses it. It scales linearly
   (one query per rendered row), is trivially safe to fix, and produces a deterministic,
   spec-assertable improvement.

## Performance measurement

### Measurement methodology

- **Environment:** `RAILS_ENV=development`, Puma, SQLite (`storage/development.sqlite3`)
  seeded via `db/seeds.rb` (80 visitors, 60 active-and-checked-in, 12 hosts) — the
  out-of-the-box state of the app.
- **Before fix:** measured on the original branch state (`origin/main`), i.e. before any of the
  fixes; **after fix:** measured on the final code with all three fixes in place. The active
  visitor count is identical in both runs (validation does not affect the seeded data).
- **Query counting:** cleared `log/development.log`, issued one HTTP `GET /api/visitors?page=1`
  with `curl`, then counted `SELECT "visitors"` and `SELECT "hosts"` statements in the log
  (the eager-load variant issues one `SELECT "hosts".* ... IN (...)` statement). Per-page
  cost is what matters here.
- **Latency:** 20 sequential `curl -w '%{time_total}'` requests to the same endpoint,
  aggregated to mean / median / min / max. The first request in each run includes a cold start
  and occasionally a code reload, which explains the higher max values.
- **Deterministic cross-check:** the request spec "eager loads hosts instead of issuing an
  N+1" counts SQL statements in-process (an `ActiveSupport::Notifications` subscription on
  `sql.active_record`) and asserts ≤ 3 statements for a full 20-row page — 21 before, 2 after.

### Results

| Metric | Before fix | After fix | Change |
|--------|-----------:|----------:|-------:|
| SQL statements per full page `GET /api/visitors?page=1` | 21 (1 visitors + 20 host lookups) | 2 (1 visitors + 1 host `IN`) | **-90.5%** |
| Mean latency (n=20) | 12.1 ms | 8.9 ms | **-26.7%** |
| Median latency (n=20) | 9.1 ms | 8.3 ms | **-8.4%** |
| Min / Max latency (n=20) | 7.3 / 47.6 ms | 2.7 / 26.0 ms | - |

On this small, local SQLite dataset the latency reduction sits inside run-to-run variance
(repeated after-fix runs varied between ~3.8 ms and ~8.9 ms median), so the meaningful,
dataset-independent improvement is the **21 → 2 query reduction**, which the regression spec
pins down deterministically. On a larger `visitors` table or a network-backed database —
where each of the 20 per-row host queries is a real round trip — the latency delta becomes
substantially larger.

## Defects deliberately not fixed

| Defect | Deliberately not fixed because | Would a fix alter the API response structure? |
|--------|-------------------------------|------------------------------------------------|
| Times rendered in UTC (timezone) | **Server side is now fixed** as part of Defect 2 (`config.time_zone = "Asia/Kathmandu"`). What remains is entirely client-side: `web/src/VisitorList.jsx` renders via `toISOString()`, which always converts to UTC for display. Per the current exercise scope (backend only), the frontend is deliberately left for a separate frontend task. | No - the remaining fix is in the web client; no API change. |
| API errors and response silently swallowed (frontend) | Client-side only (`api.js` returns `null` on non-2xx; forms always reset). Needs frontend work; pairs naturally with the Defect 2 frontend follow-up. | No - a fix is purely in the web client. |
| Pagination "Next" button enables an empty page | Frontend-only heuristic (`visitors.length < 20`). | No - client-side. |
| Malformed / non-positive `page` accepted | A strict fix would reject `page=0/-1/abc` with `400` JSON errors - a new error response path the client doesn't expect. Currently degrades silently to page 1. | **Yes** - a fix would add `400` error responses. |

## Verification summary

- Request specs: 3 runs, 0 failures (all three fail on `origin/main`, all pass on updated code).
-  Full suite: `bin/rails test` → 12 runs, 43 assertions, 0 failures.

Files changed:
- `api/app/controllers/api/visitors_controller.rb` : Defect 1 fixes.
- `api/app/models/visitor.rb` : Defect 2 fix (presence validations).
- `api/config/application.rb` : Defect 2 fix (`config.time_zone = "Asia/Kathmandu"`).
- `api/test/requests/visitors_request_test.rb` : three request specs (one per fix).
- `api/test/controllers/api/visitors_controller_test.rb` : updated the obsolete permissive-creation test.