-- Atomic write RPCs for Boletos Catalog.  DRAFT — review, then run in the Supabase SQL editor.
--
-- Replaces two best-effort client-side multi-step writes in index.html:
--   * submitAsNew()                -> submit_new_token_type()
--   * #btn-delete (withdraw/delete) -> withdraw_collection_item()
--
-- Both are SECURITY INVOKER (the default), so your existing RLS policies still apply to every
-- statement; the functions add atomicity (one transaction) and take the user id from auth.uid()
-- instead of trusting the client. Column names are inferred from index.html — verify them
-- against your real schema before running. Nothing in the client calls these yet.

-- ---------------------------------------------------------------------------------------------
-- 1. Submit a new token type + add it to the caller's collection, in one transaction.
--    Returns the new submission id.  p_submission keys mirror readFormFields() plus
--    optional id / photo_obverse_path / photo_reverse_path.
-- ---------------------------------------------------------------------------------------------
create or replace function public.submit_new_token_type(
  p_submission jsonb,
  p_quantity   integer default 1
) returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid := coalesce(nullif(p_submission->>'id', '')::uuid, gen_random_uuid());
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if p_quantity is null or p_quantity < 0 then
    raise exception 'Quantity must be a whole number >= 0' using errcode = '22023';
  end if;

  insert into token_type_submissions (
    id, submitted_by, status,
    hacienda_name, denomination, material, diameter, rarity,
    plantation_country, plantation_province, plantation_local_area,
    owner_name, owner_country, owner_province, owner_local_area,
    owner_birth_year, owner_death_year, notes,
    photo_obverse_path, photo_reverse_path
  ) values (
    v_id, v_uid, 'pending',
    p_submission->>'hacienda_name', p_submission->>'denomination', p_submission->>'material',
    (p_submission->>'diameter')::numeric, coalesce((p_submission->>'rarity')::numeric, 0),
    p_submission->>'plantation_country', p_submission->>'plantation_province',
    p_submission->>'plantation_local_area',
    p_submission->>'owner_name', p_submission->>'owner_country', p_submission->>'owner_province',
    p_submission->>'owner_local_area',
    (p_submission->>'owner_birth_year')::integer, (p_submission->>'owner_death_year')::integer,
    p_submission->>'notes',
    p_submission->>'photo_obverse_path', p_submission->>'photo_reverse_path'
  );

  insert into user_collection_items (user_id, submission_id, quantity)
  values (v_uid, v_id, p_quantity);

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Withdraw / delete one of the caller's collection items in one transaction.
--    If the item points at a still-pending submission the caller made, that submission is
--    withdrawn too (same rule as the client: only when record.pending).
--    Returns true if an item was deleted, false if it didn't exist / isn't the caller's.
-- ---------------------------------------------------------------------------------------------
create or replace function public.withdraw_collection_item(
  p_item_id uuid
) returns boolean
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid        uuid := auth.uid();
  v_submission uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  -- Item first: it references the submission.
  delete from user_collection_items
   where id = p_item_id and user_id = v_uid
  returning submission_id into v_submission;

  if not found then
    return false;
  end if;

  if v_submission is not null then
    delete from token_type_submissions
     where id = v_submission
       and submitted_by = v_uid
       and status = 'pending';
  end if;

  return true;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Permissions: signed-in users only.
-- ---------------------------------------------------------------------------------------------
revoke all on function public.submit_new_token_type(jsonb, integer) from public, anon;
revoke all on function public.withdraw_collection_item(uuid)        from public, anon;
grant execute on function public.submit_new_token_type(jsonb, integer) to authenticated;
grant execute on function public.withdraw_collection_item(uuid)        to authenticated;

-- Recommended alongside (matches the client-side readQuantity() check):
-- alter table user_collection_items
--   add constraint user_collection_items_quantity_nonneg check (quantity >= 0);

-- Client usage once deployed (replaces the two inserts / two deletes):
--   const { data: id, error } = await sb.rpc("submit_new_token_type",
--     { p_submission: Object.assign({}, fields, { id: submissionId, photo_obverse_path, photo_reverse_path }),
--       p_quantity: quantity });
--   const { data: deleted, error } = await sb.rpc("withdraw_collection_item", { p_item_id: record.collectionItemId });
