-- Server-side authorization for Boletos Catalog.  DRAFT — review, then run in the Supabase SQL editor.
--
-- index.html only *hides* admin UI behind ADMIN_UID; the real boundary is what's below.
-- I have not seen your current policies or the bodies of approve_submission / reject_submission,
-- so this file is a proposed target state inferred from index.html. Run SECTION 0 first, compare it
-- with what's here, and apply section by section. Test as a normal user, as the admin and as anon
-- (Supabase "Run as" role, or the client with each session) before relying on it.

-- =============================================================================================
-- SECTION 0 — AUDIT (read-only). Run these and read the output before changing anything.
-- =============================================================================================
-- select tablename, rowsecurity from pg_tables where schemaname = 'public';
-- select tablename, policyname, cmd, roles, qual, with_check from pg_policies
--   where schemaname in ('public', 'storage') order by 1, 2;
-- select proname, prosecdef as security_definer, pg_get_functiondef(oid)
--   from pg_proc where pronamespace = 'public'::regnamespace
--   and proname in ('match_token_types', 'approve_submission', 'reject_submission');
-- select grantee, privilege_type, table_name from information_schema.role_table_grants
--   where table_schema = 'public' and grantee in ('anon', 'authenticated');
-- select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'boleto-photos';

-- =============================================================================================
-- SECTION 1 — Who is an admin (replaces the JS-only ADMIN_UID check)
-- =============================================================================================
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);
alter table public.admins enable row level security;   -- no policies: clients can't read or write it
revoke all on public.admins from anon, authenticated;

-- Seed with the UID currently hardcoded as ADMIN_UID in index.html.
insert into public.admins (user_id) values ('aa055f08-f805-4b53-992f-9130b926fea6')
on conflict do nothing;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.admins where user_id = auth.uid()) $$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- =============================================================================================
-- SECTION 2 — token_types (the master catalog): world-readable, changed only by admins
--             (approve_submission below inserts as security definer).
-- =============================================================================================
alter table public.token_types enable row level security;

drop policy if exists token_types_read on public.token_types;
create policy token_types_read on public.token_types
  for select to anon, authenticated using (true);

drop policy if exists token_types_admin_write on public.token_types;
create policy token_types_admin_write on public.token_types
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- =============================================================================================
-- SECTION 3 — token_type_submissions
--   users: see/insert/edit/withdraw their own *pending* submissions
--   admin: sees everything; approves/rejects only through the RPCs in section 5
-- =============================================================================================
alter table public.token_type_submissions enable row level security;

drop policy if exists subs_select on public.token_type_submissions;
create policy subs_select on public.token_type_submissions
  for select to authenticated using (submitted_by = auth.uid() or public.is_admin());

drop policy if exists subs_insert on public.token_type_submissions;
create policy subs_insert on public.token_type_submissions
  for insert to authenticated
  with check (submitted_by = auth.uid() and status = 'pending' and admin_note is null);

drop policy if exists subs_update_own_pending on public.token_type_submissions;
create policy subs_update_own_pending on public.token_type_submissions
  for update to authenticated
  using (submitted_by = auth.uid() and status = 'pending')
  with check (submitted_by = auth.uid() and status = 'pending');

drop policy if exists subs_delete_own_pending on public.token_type_submissions;
create policy subs_delete_own_pending on public.token_type_submissions
  for delete to authenticated using (submitted_by = auth.uid() and status = 'pending');

-- Users may edit descriptive fields only — never status / admin_note / submitted_by.
-- (Admin changes go through the SECURITY DEFINER RPCs, which bypass these column grants.)
revoke update on public.token_type_submissions from authenticated;
grant update (hacienda_name, denomination, material, diameter, rarity,
              plantation_country, plantation_province, plantation_local_area,
              owner_name, owner_country, owner_province, owner_local_area,
              owner_birth_year, owner_death_year, notes,
              photo_obverse_path, photo_reverse_path)
  on public.token_type_submissions to authenticated;

-- =============================================================================================
-- SECTION 4 — user_collection_items: strictly per-user
-- =============================================================================================
alter table public.user_collection_items enable row level security;

drop policy if exists items_select on public.user_collection_items;
create policy items_select on public.user_collection_items
  for select to authenticated using (user_id = auth.uid());

-- A submission_id may only reference a submission the caller made.
drop policy if exists items_insert on public.user_collection_items;
create policy items_insert on public.user_collection_items
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and (submission_id is null or exists (
          select 1 from public.token_type_submissions s
          where s.id = submission_id and s.submitted_by = auth.uid()))
  );

drop policy if exists items_update on public.user_collection_items;
create policy items_update on public.user_collection_items
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists items_delete on public.user_collection_items;
create policy items_delete on public.user_collection_items
  for delete to authenticated using (user_id = auth.uid());

-- Only quantity / personal_notes are user-editable (not user_id, token_type_id, submission_id).
revoke update on public.user_collection_items from authenticated;
grant update (quantity, personal_notes) on public.user_collection_items to authenticated;

alter table public.user_collection_items
  drop constraint if exists user_collection_items_quantity_nonneg,
  add  constraint user_collection_items_quantity_nonneg check (quantity >= 0);

-- =============================================================================================
-- SECTION 5 — approve / reject: admin-only, enforced in the database
--   Reference implementations. If your existing functions already do an equivalent admin check,
--   keep them. CHECK these assumptions against your schema before replacing:
--     * token_types has the same descriptive columns as token_type_submissions
--     * submissions have status values 'pending' | 'approved' | 'rejected' and an admin_note column
--     * user_collection_items may hold token_type_id AND submission_id at once (the client reads
--       token_type_id first). If you have a "exactly one of" CHECK, null submission_id below instead.
-- =============================================================================================
create or replace function public.approve_submission(p_submission_id uuid, overrides jsonb default '{}'::jsonb)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  s  public.token_type_submissions;
  v  public.token_type_submissions;   -- submission with admin overrides applied
  tt uuid;
begin
  if not public.is_admin() then
    raise exception 'Admin only' using errcode = '42501';
  end if;

  select * into s from public.token_type_submissions
   where id = p_submission_id for update;
  if not found then raise exception 'Submission not found' using errcode = 'P0002'; end if;
  if s.status <> 'pending' then raise exception 'Submission is not pending' using errcode = '22023'; end if;

  v := jsonb_populate_record(null::public.token_type_submissions,
                             to_jsonb(s) || coalesce(overrides, '{}'::jsonb));

  -- Whitelisted copy: overrides can never change status, submitted_by, id, etc.
  insert into public.token_types (
    hacienda_name, denomination, material, diameter, rarity,
    plantation_country, plantation_province, plantation_local_area,
    owner_name, owner_country, owner_province, owner_local_area,
    owner_birth_year, owner_death_year, notes, photo_obverse_path, photo_reverse_path
  ) values (
    v.hacienda_name, v.denomination, v.material, v.diameter, v.rarity,
    v.plantation_country, v.plantation_province, v.plantation_local_area,
    v.owner_name, v.owner_country, v.owner_province, v.owner_local_area,
    v.owner_birth_year, v.owner_death_year, v.notes, s.photo_obverse_path, s.photo_reverse_path
  ) returning id into tt;

  update public.user_collection_items set token_type_id = tt where submission_id = s.id;
  update public.token_type_submissions set status = 'approved' where id = s.id;
  return tt;
end;
$$;

create or replace function public.reject_submission(p_submission_id uuid, p_note text default null)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin only' using errcode = '42501';
  end if;
  update public.token_type_submissions
     set status = 'rejected', admin_note = p_note
   where id = p_submission_id and status = 'pending';
  if not found then raise exception 'Submission not found or not pending' using errcode = 'P0002'; end if;
end;
$$;

revoke all on function public.approve_submission(uuid, jsonb) from public, anon;
revoke all on function public.reject_submission(uuid, text)   from public, anon;
grant execute on function public.approve_submission(uuid, jsonb) to authenticated;
grant execute on function public.reject_submission(uuid, text)   to authenticated;

-- =============================================================================================
-- SECTION 6 — match_token_types: leave SECURITY INVOKER (default); it only reads token_types,
--             which is public. Make sure it is NOT security definer and cannot read submissions.
-- =============================================================================================

-- =============================================================================================
-- SECTION 7 — Storage bucket boleto-photos
--   The client uploads to "<draft-uuid>/obverse|reverse.jpg" BEFORE the submission row exists,
--   so ownership can't be tied to a submissions row: restrict by path shape + uploader instead.
--   Reads go through getPublicUrl(), so the bucket must stay public (no select policy needed).
-- =============================================================================================
update storage.buckets
   set file_size_limit = 2 * 1024 * 1024, allowed_mime_types = array['image/jpeg']
 where id = 'boleto-photos';

drop policy if exists photos_insert on storage.objects;
create policy photos_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'boleto-photos'
              and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(obverse|reverse)\.jpg$');

-- upsert:true needs UPDATE; only the original uploader (or admin) may overwrite / delete.
drop policy if exists photos_update on storage.objects;
create policy photos_update on storage.objects
  for update to authenticated
  using (bucket_id = 'boleto-photos' and (owner_id = auth.uid()::text or public.is_admin()))
  with check (bucket_id = 'boleto-photos' and (owner_id = auth.uid()::text or public.is_admin()));

drop policy if exists photos_delete on storage.objects;
create policy photos_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'boleto-photos' and (owner_id = auth.uid()::text or public.is_admin()));
