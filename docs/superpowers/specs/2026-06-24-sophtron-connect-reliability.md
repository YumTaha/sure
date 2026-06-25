# Sophtron Connect Reliability Fixes

**Date:** 2026-06-24
**Status:** SHIPPED (PR #9, merged to main as `5a1407f5`)
**Primary file:** `app/controllers/sophtron_items_controller.rb` (all fixes unless noted)

---

## Background

Apple Card failing to connect exposed several independent reliability gaps in the Sophtron connect/poll flow. The fixes were unplanned but shipped together as PR #9. Each fix is self-contained.

---

## Correctness note — `SuccessFlag` is tri-state

`SuccessFlag` is `null` (in-progress) / `true` / `false`. `AccountsReady` as a `LastStatus` value is NOT "done" — Sophtron can report `LastStatus=AccountsReady` with `SuccessFlag=null` for 60-80 seconds before flipping to `SuccessFlag=true`. All `SuccessFlag` reads in the controller use explicit `== true` / `== false` so `null` is never collapsed to `false`. The existing `job_success?` still advances on `AccountsReady` (kept deliberately — works for fast banks; the reliability fixes handle the slow-bank case without changing that path's minimal scope).

---

## Fixes

### 1. Poll window too short (commit `21ac5c0d`)

After an MFA code clears, Sophtron sits at `LastStatus=AccountsReady` with `SuccessFlag=null` for ~60-80 seconds before flipping to `SuccessFlag=true`. Push-approval ("Allow on phone") logins are similarly slow. The previous caps were 15 polls × 4 s = 60 s — just short enough to time out on slow banks.

**Fix:** Raised `LOGIN_PROGRESS_CONNECTION_STATUS_MAX_POLLS` and `POST_MFA_CONNECTION_STATUS_MAX_POLLS` from 15 to 38 (~152 s).

---

### 2. MFA re-prompt trap (commit `21ac5c0d`)

After a user submits an MFA answer, Sophtron lags a few seconds still reporting the same challenge step (the submitted value is not yet registered server-side). The poller was re-rendering the code form and asking the user for the same code again.

**Fix:** Record the answered step in session keyed by MFA type (`MFA_ANSWER_GRACE_SECONDS = 45`, measured from submit time). Within the grace window, keep polling silently instead of re-prompting. Re-prompt only on a different challenge type or after the grace expires.

---

### 3. No-MFA connect timed out at "Attempt 6 of 6" (commit `b113c94e`)

A push-approval connect (no code entered, `post_mfa=false`) reaches `LastStatus=Completed` on `LogInPanel` with `SuccessFlag=null`. Two causes:

**(a)** `"Completed"` is a member of `FAILURE_JOB_STATUSES`, so the string-only `failure_job_status?` flagged a still-working job as failed, and `login_progress_job_payload?` collapsed the poll cap to the short 24 s default.

**(b)** The accounts-available check (`render_account_selection_if_accounts_available`) only ran inside `if post_mfa_polling?`, which a no-MFA connect never enters.

**Fix:** Gate the "still connecting" determination on the `SuccessFlag`-aware `Provider::Sophtron.job_failed?` instead of the bare status string. Run `render_account_selection_if_accounts_available` on `job_completed?` for all flows, not only post-MFA.

---

### 4. "Check again" race (commit `4f3e56ae`)

Also touches: `app/views/sophtron_items/connection_status.html.erb`

The manual "Check again" button was visible during live auto-polling. Clicking it advanced the poll counter and raced the auto-poller, causing double-advances and inconsistent state.

**Fix:** Render "Check again" only once `@timed_out` is set (recovery state), not during active polling.

---

### 5. White screen on retry after a failed connect (commit `bf2132ad`)

Also touches: `app/views/sophtron_items/_api_error.html.erb`

The api_error dialog's retry button used `data: { turbo: false }` (full navigation) but pointed at `select_accounts`, which renders `layout: false` (a bare turbo-frame fragment). A full-navigation request to a layout-less fragment painted a blank/white page.

**Fix:** Made the button's `data` attribute configurable via an `action_data` local (default `{ turbo: false }` for real-page targets). The institution-connection-error retry passes `{ turbo_frame: "modal" }` so the connect form swaps into the modal frame instead of triggering a full navigation.

---

### 6. Copilot follow-up — stale MFA grace on quick reconnect (commit `0c2243cb`)

The `completed-with-accounts` exit path did not call `clear_mfa_answer_grace!`, while the `job_success?` and `job_failed?` branches did. A stale grace entry from a prior session could suppress a new same-type MFA prompt on a quick reconnect.

**Fix:** Added `clear_mfa_answer_grace!` to the completed-with-accounts exit path to match the other branches.
