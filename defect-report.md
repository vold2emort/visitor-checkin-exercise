# Visitor Check-in Defect Report

This report documents every defect found while exploring the application, based on the
feature specification in the repository README:

- A receptionist can register a visitor with a full name, company name, host employee, and purpose of visit.
- Registered visitors appear in an active visitor list, showing check-in time.
- A visitor can be checked out, which removes them from the active list.
- A visitor record can be deactivated by an administrator. Deactivated visitors **must not**
  appear in the active list and **must not be selectable when registering a repeat visit**.
- The active visitor list is paginated at twenty records per page.
- All times are displayed in the receptionist's local timezone.

---

## 1. Deactivated visitors still appear in the active list

- **Summary:** Deactivated visitors who have not been checked out remain visible in the active visitor list.
- **Type:** Functional
- **Description:**
  `Visitors#index` (api/app/controllers/api/visitors_controller.rb:7) only filters on `checked_out_at: nil`:

  ```ruby
  visitors = Visitor.where(checked_out_at: nil).order(:id)...
  ```

  It never filters on `active`. A visitor whose `active` flag was set to `false` (deactivated) but
  who was never checked out is still returned and rendered in the active list. This directly contradicts
  the specification: "Deactivated visitors must not appear in the active list."
  The seed data masks this in development because every seeded deactivated visitor is _also_ given a
  `checked_out_at` timestamp (db/seeds.rb:64), so they are filtered out for the wrong reason.

- **Steps to Reproduce:**
  1. Start the API and seed the database (`rails db:seed`).
  2. Open a Rails console and pick a checked-in, active visitor and set `visitor.update!(active: false)`.
  3. Load the active visitor list, e.g. `GET /api/visitors?page=1` or open the frontend.
  4. Observe that the deactivated visitor is still in the returned list / still shown.
- **Expected Result:** Deactivated visitors must not appear in the active visitor list, immediately after deactivation.
- **Actual Result:** The deactivated visitor remains in the active list until it is manually checked out.

---

## 2. Deactivated visitors are returned by the repeat-visit search

- **Summary:** The name search used for registering visitors returns deactivated visitors, making them selectable.
- **Type:** Functional
- **Description:**
  `Visitors#search` (api/app/controllers/api/visitors_controller.rb:39) queries all visitors:

  ```ruby
  visitors = Visitor.where("full_name LIKE ?", "%#{q}%").order(:full_name).limit(10)
  ```

  It has no `active` filter. The frontend autocomplete (`RegistrationForm`) uses this endpoint to fill in
  the form for visitors. Because deactivated records are returned, a receptionist can select a
  deactivated visitor's name and register a new visit for them, violating the requirement that deactivated
  visitors "must not be selectable when registering a repeat visit."

- **Steps to Reproduce:**
  1. Ensure a deactivated visitor exists (e.g. `Sam Inactive`, active: false).
  2. In the registration form, type the first two characters of their name (e.g. "Sa").
  3. Observe the deactivated visitor appears in the autocomplete dropdown and can be clicked to fill the form.
  4. (Alternatively) call `GET /api/visitors/search?q=Sam` and observe the deactivated record in the response.
- **Expected Result:** Deactivated visitors are excluded from search results and cannot be selected for a repeat visit.
- **Actual Result:** Deactivated visitors are returned and selectable.

---

## 3. N+1 query load in the active visitor list

- **Summary:** Rending the active list issues one query per visitor for its host (N+1), scaling poorly.
- **Type:** Performance
- **Description:**
  `Visitors#index` loads the current page of visitors (up to 20) and then calls `serialize(v)` for each,
  which accesses `visitor.host&.name` (api/app/controllers/api/visitors_controller.rb:12, :61). There is no
  eager loading (`includes`), so with a full page of 20 visitors ActiveRecord issues 1 `SELECT` for the
  visitors and then 20 individual `SELECT` queries for each host — 21 queries per page request. This grows
  linearly and adds a round trip per row; it becomes a visible latency problem as the visitor table grows.
  This is the primary performance defect identified in the application.
- **Steps to Reproduce:**
  1. Ensure at least 20 active visitors belonging to various hosts exist.
  2. Enable SQL logging (default in development) and clear `log/development.log`.
  3. `GET /api/visitors?page=1`.
  4. Count the resulting `SELECT` statements in the log.
- **Expected Result:** Host names should be loaded with eager loading — 2 queries total (visitors + hosts IN).
- **Actual Result:** 21 queries for a full page (1 visitors query + 20 per-row host queries).

---

## 4. No server-side validation, empty/incomplete visitor records can be created

- **Summary:** `POST /api/visitors` accepts empty or incomplete records; the API has no required-field validation.
- **Type:** Data integrity (requirement gap / missing validation)
- **Description:**
  The API permits any combination of `full_name`, `company_name`, `purpose`, and `host_id`
  (api/app/controllers/api/visitors_controller.rb:47-49). A `POST` with an empty body creates a fully
  blank visitor. The frontend registration form only enforces `required` on `full_name` and `host_id` client-side;
  `company_name` and `purpose` are optional in the UI too, even though the specification lists all four as
  part of registering a visitor.
- **Steps to Reproduce:**
  1. `POST /api/visitors` with `Content-Type: application/json` and body `{}` (or omit all fields).
  2. Observe HTTP 201 Created and a persisted row with `full_name`, `company_name`, `purpose`, `host_id` all `NULL`.
  3. In the UI, submit the form leaving Company and Purpose empty — a record is created without them.
- **Expected Result:** A 422 Unprocessable Entity response listing validation errors; only well-formed visitor records are persisted. Company name and purpose should be required per the feature spec.
- **Actual Result:** Blank/incomplete records are persisted with 201. New record with null fields is created.

---

## 5. Check-in times are always rendered in UTC, never the receptionist's local timezone

- **Summary:** The Backend has no to make the time format to local timezone rendering UTC (sent by frontend) regardless of the user's timezone.
- **Type:** Functional (frontend / timezone)
- **Description:**

  The backend is saving the time in utc not local Asia/Kathmandu timezone, the frontend is responsible for displaying the time by UTC+5:45. The server itself is not saving the local time.

  `toISOString()` always converts to UTC, so the displayed clock time is UTC, not the receptionist's local
  time. On the server, `config.time_zone` is never set (api/config/application.rb:36), so `Time.current`
  is UTC and ISO timestamps are serialized with a `Z` suffix. The net effect: for a user in Asia/Kathmandu
  (UTC+5:45), a visitor checked in at 10:00 local is displayed as 04:15. The app is explicitly designed for
  the Asia/Kathmandu timezone, and two seeded visitors are even given intentional overnight Kathmandu
  check-in times (db/seeds.rb:55,59 → 23:30 and 01:05). This is the root cause of the note that behavior
  looks plausible during mid-day working hours but is visibly wrong at other times of day.

- **Steps to Reproduce:**
  1. Ensure the machine/browser timezone is anything other than UTC (e.g. Asia/Kathmandu).
  2. Register a visitor at a known local time, e.g. 10:00.
  3. Look at the "Checked In" column in the active visitor list.
  4. Also observe the seeded visitors whose seeds use the Kathmandu offset (indices 4 and 10).
- **Expected Result:** The displayed time reflects the receptionist's local timezone (e.g. 10:00).
- **Actual Result:** The displayed time is always UTC (e.g. 04:15), i.e. shifted by the user's UTC offset (5h45m for Kathmandu).

---

## 6. API response are silently swallowed; the UI gives no feedback on failures

- **Summary:** Failed requests return `null`, and forms clear as if the operation succeeded.
- **Type:** Usability
- **Description:**
  If the form is registered sucessfully the form input field clears and there is no success or error displayed to let the user know if the action is successful or an error occured.
  `web/src/api.js:8-10` returns `null` whenever the response is not `ok`. Callers do not distinguish
  `null` from an empty result. `RegistrationForm.handleSubmit` (web/src/RegistrationForm.jsx:34-40)
  always resets the form and calls `onRegistered()` after `createVisitor(...)`, regardless of whether the
  POST succeeded. `VisitorList.handleCheckOut` (web/src/VisitorList.jsx:18-21) optimistically removes the
  row and never checks the result. A lost request or server error therefore looks like success to the user,
  and the newly registered visitor silently vanishes from the list.
- **Steps to Reproduce:**
  1. Open the app and stop the API server (or temporarily break the endpoint).
  2. Fill the registration form and submit.
  3. Observe: the form clears and no error is shown.
  4. Check the active visitor list — the visitor is not there.
- **Expected Result:** On failure the user sees an error message and the entered data is preserved.
- **Actual Result:** The operation fails silently; the form is cleared and the visitor never appears.

---


## 7. `check_out` and `deactivate` do not guard against current state

- **Summary:** Repeated check-out overwrites the check-out timestamp; deactivation of a checked-in visitor leaves them listed.
- **Type:** Functional (minor)
- **Description:**
  `Visitors#check_out` (visitors_controller.rb:25-29) blindly writes `checked_out_at: Time.current`,
  so calling it twice silently moves the recorded check-out time forward. `Visitors#deactivate`
  (visitors_controller.rb:31-35) toggles `active` but does not check out or otherwise handle the current
  state, so a deactivated visitor who is still checked in remains in the active list (compounds D1). Neither
  endpoint distinguishes "already in this state" from a real transition.
- **Steps to Reproduce:**
  1. Check out a visitor: `PATCH /api/visitors/:id/check_out`, note the time.
  2. Wait, then `PATCH ... /check_out` again on the same visitor.
  3. Read the visitor record — `checked_out_at` now equals the second call's time.
  4. Separately, deactivate an active, checked-in visitor and load the active list — they are still listed.
- **Expected Result:** Check-out is idempotent (or returns a conflict/error on a second call); deactivated visitors disappear from the active list.
- **Actual Result:** Timestamps are silently overwritten; deactivation does not remove the visitor from the active list by itself.

---

## 8. Pagination "Next" button enables a useless empty page

- **Summary:** When a page returns exactly 20 rows but nothing follows, the Next button is still clickable.
- **Type:** Usability
- **Description:**
  The Next button is enabled whenever the current page returned 20 visitors
  (web/src/VisitorList.jsx:57, `disabled={visitors.length < 20}`). With exactly 20 active visitors
  (i.e. no next page), the button is clickable and leads to an empty page with the button then disabling.
- **Steps to Reproduce:**
  1. Ensure exactly 20 active visitors are checked in.
  2. Open the active visitor list and click "Next".
- **Expected Result:** The Next button is disabled because there is no further page of data.
- **Actual Result:** An empty page 2 is shown.

---

## 9. Non-positive / malformed `page` parameter degrades silently to page 1

- **Summary:** `page=0`, `page=-1`, and non-numeric values are accepted and return the first page.
- **Type:** Data (minor) / API robustness
- **Description:**
  `(params[:page] || 1).to_i` (visitors_controller.rb:6) coerces any value to an integer. Negative and zero
  values produce a negative OFFSET, which SQLite silently clamps to 0, yielding the first page again;
  non-numeric strings coerce to 0 with the same result.
- **Steps to Reproduce:**
  1. `GET /api/visitors?page=0`, then `GET /api/visitors?page=-1`, then `GET /api/visitors?page=abc`.
  2. Compare each response to `GET /api/visitors?page=1`.
- **Expected Result:** Unsupported page values should either be rejected (400) or normalized deliberately (no silent duplication / surpressed errors).
- **Actual Result:** All three silently return the first page of data, indistinguishable from a valid request.

---

## Assumptions & requirement gaps (not treated as defects)

The issues below are ambiguity with the specification rather than clear defects.

- **1. No authentication / role separation but in readme said visitor are deactivated by admin.**
  The spec distinguishes "receptionist" from "administrator" (only admins deactivate visitors), but the
  application has no authentication or authorization anywhere; `PATCH /deactivate` is unauthenticated and
  unverified. Assumed roles and access control are intentionally out of scope for this exercise.

- **2. Repeat visits create a new record every time.**
  Selecting a name in the autocomplete pre-fills the form and submission creates a brand-new `Visitor`
  record. There is no guard preventing the same person from being checked in twice at once. Assumed that a
  separate visit record per occurrence is the intended model; only explicitly _deactivated_ records are
  prohibited from selection (which Defect 2 covers).

- **3. Host may be `NULL` at the data layer.**
  `Visitor.belongs_to :host, optional: true` and the schema has no `NOT NULL` on `host_id`, even though the
  UI requires a host. Tied to Defect 4: without validation this is reachable via the API.
