# Boletos Catalog

A single-page web app for cataloging historical coffee hacienda **boletos** (payment
tokens). Everything lives in one file: [index.html](index.html) (~1,570 lines: inline
CSS + vanilla JS, no build step, no framework).

## Architecture

- **No bundler/framework** — plain HTML/CSS/JS in `index.html`. Open it directly in a
  browser or serve it as a static file.
- **Backend: Supabase** (see script tag near line 565, client init ~line 567-570).
  The publishable/anon key is embedded client-side (expected for Supabase's public key model —
  access control is enforced via Supabase row-level security policies, not by hiding the key).
- **Admin:** a single hardcoded `ADMIN_UID` constant (~line 568) drives `isAdmin`, which only
  gates the UI (Review tab, badge). **Real enforcement must live server-side** (RLS +
  the RPCs below). Those SQL definitions are not in this repo — verify them in Supabase.
- **Supabase RPCs used:** `match_token_types(query)` (duplicate matching before a submission),
  `approve_submission(p_submission_id, overrides)`, `reject_submission(p_submission_id, p_note)`.
- **Tables used:**
  - `token_types` — the catalog of known boleto/token types (hacienda name, etc.)
  - `user_collection_items` — a signed-in user's personal collection (quantity,
    personal notes, links to a token type)
  - `token_type_submissions` — user-submitted new token types awaiting moderation
    (`status = "pending"` → review queue)
  - Storage bucket `boleto-photos` — uploaded photos for tokens/submissions
- **Auth:** Supabase auth (email/password sign in/up/out), see `#auth-form` /
  `#auth-controls` in the HTML and the auth handlers in the script.
- **i18n:** Simple `data-i18n` / `data-i18n-placeholder` attribute-driven translation
  system, English/Spanish, language persisted in `localStorage` (`LANG_KEY`).

## Key features (for context, not exhaustive)

- Browse/search/sort the full token catalog; stats bar (total tokens, haciendas count).
- "My collection" view — signed-in users track owned tokens with quantity + notes.
- Adding a token: the form first calls `match_token_types`; the user can link to an existing
  token type or submit a new one (`status = "pending"`).
- "Review queue" (admin only) — pending submissions with a badge count; approve/reject via RPCs.
- Export catalog/collection as JSON and CSV.
- Photo upload for token submissions, stored in Supabase Storage.

## Working on this project

- It's a single large HTML file — when making changes, `grep` for the relevant
  `id="..."` or function name first rather than reading the whole file (it exceeds
  typical single-read size limits).
- No test suite or build/lint tooling currently exists.
- **Error handling conventions:** view loaders in `VIEW_LOADERS` throw on Supabase errors;
  `setView` catches, sets `loadError`, and `render()` shows the localized `loadError`
  message in the empty-state area. Multi-step writes check each `error` result.
- **i18n:** add every new user-facing string to *both* `en` and `es` in `translations`.
- No `.env`/config file — Supabase URL and anon key are hardcoded constants near the
  top of the `<script>` block.

## Status

Initial commit `e03086a` (2026-07-14).

Session 3 (2026-10-07): re-implemented the lost Session 2 fixes in `index.html`:
- View loaders throw on Supabase errors; `setView` sets `loadError` and `render()` shows the localized message.
- `submitAsNew` deletes the submission if the collection-item insert fails (warns if cleanup also fails).
- Withdraw/delete checks the error on each delete.
- Quantity is validated by `readQuantity()` (empty → 1; must be a whole number ≥ 0, else alert `invalidQuantity`). The DB should also enforce this with a CHECK constraint on `user_collection_items.quantity`.

## Known issues / next steps

- Confirm `approve_submission` / `reject_submission` and RLS on `token_type_submissions`,
  `user_collection_items`, and `boleto-photos` verify the caller server-side (not just `ADMIN_UID` in JS).
- Writes are still not truly atomic (rollback is best-effort client-side). Proper fix:
  a Supabase RPC that inserts submission + collection item in one transaction, and one for withdraw.
- Errors are shown with `alert()`; Supabase JS is loaded from unpinned `@2`.
