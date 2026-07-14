# Boletos Catalog

A single-page web app for cataloging historical coffee hacienda **boletos** (payment
tokens). Everything lives in one file: [index.html](index.html) (~1,570 lines: inline
CSS + vanilla JS, no build step, no framework).

## Architecture

- **No bundler/framework** — plain HTML/CSS/JS in `index.html`. Open it directly in a
  browser or serve it as a static file.
- **Backend: Supabase** (see script tag near line 565, client init ~line 567-570).
  The anon key is embedded client-side (expected for Supabase's public/anon key model —
  access control is enforced via Supabase row-level security policies, not by hiding the key).
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
- "Review queue" — pending user submissions of new token types, with a badge count.
- Export catalog/collection as JSON and CSV.
- Photo upload for token submissions, stored in Supabase Storage.

## Working on this project

- It's a single large HTML file — when making changes, `grep` for the relevant
  `id="..."` or function name first rather than reading the whole file (it exceeds
  typical single-read size limits).
- No test suite or build/lint tooling currently exists.
- No `.env`/config file — Supabase URL and anon key are hardcoded constants near the
  top of the `<script>` block.

## Status

Initial commit only (`e03086a`) as of 2026-07-14. No further history yet.
