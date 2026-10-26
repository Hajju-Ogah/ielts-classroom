-- ════════════════════════════════════════════════════════════════════
--  SHEKINAH IELTS CLASSROOM · Supabase setup
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  It is safe to run again later (for example when you receive an update):
--  it never deletes your student's work.
-- ════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto with schema extensions;

-- ─────────────────────────────── TABLES ───────────────────────────────

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  role text not null default 'student' check (role in ('tutor', 'student')),
  created_at timestamptz not null default now()
);

create table if not exists public.lessons (
  day int primary key,
  title text not null,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.lesson_private (
  day int primary key references public.lessons(day) on delete cascade,
  notes jsonb not null default '[]'::jsonb
);

create table if not exists public.task_private (
  task_id text primary key,
  day int not null references public.lessons(day) on delete cascade,
  kind text not null,
  auto boolean not null default true,
  key jsonb,
  script jsonb,
  model jsonb,
  notes text,
  plays int not null default 1
);

create table if not exists public.day_access (
  student_id uuid not null references public.profiles(id) on delete cascade,
  day int not null references public.lessons(day) on delete cascade,
  unlocked_at timestamptz not null default now(),
  primary key (student_id, day)
);

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  day int not null,
  task_id text not null,
  answers jsonb not null default '{}'::jsonb,
  meta jsonb not null default '{}'::jsonb,
  status text not null default 'draft' check (status in ('draft', 'submitted')),
  submitted_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (student_id, task_id)
);

create table if not exists public.listening_plays (
  student_id uuid not null references public.profiles(id) on delete cascade,
  task_id text not null,
  plays int not null default 0,
  last_played_at timestamptz,
  primary key (student_id, task_id)
);

create table if not exists public.markings (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  day int not null,
  task_id text not null,
  auto jsonb,
  overrides jsonb not null default '{}'::jsonb,
  band numeric(3,1),
  criteria jsonb not null default '{}'::jsonb,
  comments text,
  strengths jsonb not null default '[]'::jsonb,
  improvements jsonb not null default '[]'::jsonb,
  corrected_version text,
  item_feedback jsonb not null default '{}'::jsonb,
  source text,
  updated_at timestamptz not null default now(),
  unique (student_id, task_id)
);

create table if not exists public.day_reports (
  student_id uuid not null references public.profiles(id) on delete cascade,
  day int not null,
  overall_comment text,
  next_steps jsonb not null default '[]'::jsonb,
  error_log jsonb not null default '[]'::jsonb,
  released boolean not null default false,
  released_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (student_id, day)
);

create table if not exists public.corrections (
  student_id uuid not null references public.profiles(id) on delete cascade,
  task_id text not null,
  day int not null,
  body jsonb not null default '{}'::jsonb,
  submitted_at timestamptz,
  tutor_comment text,
  reviewed boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (student_id, task_id)
);

create table if not exists public.tutor_notes (
  student_id uuid primary key references public.profiles(id) on delete cascade,
  note text,
  updated_at timestamptz not null default now()
);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

create table if not exists public.board_pages (
  id text primary key,
  title text not null default 'Page',
  background text not null default 'blank',
  sort int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.board_items (
  id text primary key,
  page_id text not null references public.board_pages(id) on delete cascade,
  data jsonb not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.classroom (
  id int primary key default 1 check (id = 1),
  room_key uuid not null default gen_random_uuid(),
  state jsonb not null default '{}'::jsonb
);

create index if not exists submissions_student_day on public.submissions (student_id, day);
create index if not exists markings_student_day on public.markings (student_id, day);
create index if not exists board_items_page on public.board_items (page_id, created_at);
create index if not exists chat_created on public.chat_messages (created_at);

-- ─────────────────────────────── HELPERS ──────────────────────────────

create or replace function public.is_tutor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'tutor');
$$;

create or replace function public.norm_answer(t text) returns text
language sql immutable as $$
  select regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', '', 'g');
$$;

create or replace function public.strip_articles(t text) returns text
language sql immutable as $$
  select regexp_replace(lower(btrim(coalesce(t, ''))), '^(the|a|an)\s+', '');
$$;

create or replace function public.answer_matches(p_answer text, p_accepted jsonb) returns boolean
language sql immutable as $$
  select case
    when public.norm_answer(p_answer) = '' or p_accepted is null or jsonb_typeof(p_accepted) <> 'array' then false
    else exists (
      select 1 from jsonb_array_elements_text(p_accepted) a
      where public.norm_answer(a) = public.norm_answer(p_answer)
         or public.norm_answer(public.strip_articles(a)) = public.norm_answer(public.strip_articles(p_answer))
    )
  end;
$$;

-- Recompute score/correct flags from automatic results plus tutor/Claude overrides.
create or replace function public.apply_overrides(p_auto jsonb, p_over jsonb) returns jsonb
language plpgsql immutable as $$
declare
  v_items jsonb := '{}'::jsonb;
  v_q text; v_item jsonb; v_final boolean; v_score int := 0; v_total int := 0;
begin
  if p_auto is null or p_auto -> 'items' is null then return p_auto; end if;
  for v_q, v_item in select key, value from jsonb_each(p_auto -> 'items') loop
    v_final := coalesce((p_over ->> v_q)::boolean, (v_item ->> 'auto')::boolean, false);
    v_total := v_total + 1;
    if v_final then v_score := v_score + 1; end if;
    v_items := v_items || jsonb_build_object(v_q, v_item || jsonb_build_object('correct', v_final));
  end loop;
  return p_auto || jsonb_build_object('score', v_score, 'total', v_total, 'items', v_items);
end $$;

create or replace function public.refresh_auto(p_student uuid, p_task text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_key jsonb; v_auto boolean; v_day int; v_answers jsonb; v_status text; v_over jsonb;
  v_items jsonb := '{}'::jsonb; v_q text; v_acc jsonb; v_ans text;
begin
  select key, auto, day into v_key, v_auto, v_day from public.task_private where task_id = p_task;
  if v_key is null or jsonb_typeof(v_key) <> 'object' or v_auto is false then return; end if;
  select answers, status into v_answers, v_status from public.submissions where student_id = p_student and task_id = p_task;
  if v_status is distinct from 'submitted' then return; end if;
  select overrides into v_over from public.markings where student_id = p_student and task_id = p_task;
  for v_q, v_acc in select key, value from jsonb_each(v_key) loop
    v_ans := coalesce(v_answers ->> v_q, '');
    v_items := v_items || jsonb_build_object(v_q, jsonb_build_object(
      'answer', v_ans, 'auto', public.answer_matches(v_ans, v_acc), 'accepted', v_acc));
  end loop;
  insert into public.markings as m (student_id, day, task_id, auto, source)
  values (p_student, v_day, p_task, public.apply_overrides(jsonb_build_object('items', v_items), coalesce(v_over, '{}'::jsonb)), 'auto')
  on conflict (student_id, task_id) do update
    set auto = public.apply_overrides(jsonb_build_object('items', v_items), m.overrides),
        updated_at = now();
end $$;

-- ─────────────────────────────── TRIGGERS ─────────────────────────────

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

-- New sign-ups get a classroom profile automatically.
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'ielts_on_auth_user_created') then
    create trigger ielts_on_auth_user_created after insert on auth.users
      for each row execute function public.handle_new_user();
  end if;
exception when others then
  raise notice 'Could not add the sign-up trigger (%). Accounts are still linked each time you run this file.', sqlerrm;
end $$;

create or replace function public.handle_new_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role = 'student' and exists (select 1 from public.lessons where day = 1) then
    insert into public.day_access (student_id, day) values (new.id, 1) on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists on_profile_created on public.profiles;
create trigger on_profile_created after insert on public.profiles
  for each row execute function public.handle_new_profile();

-- When the tutor (or an imported marking) changes overrides, recompute the score.
create or replace function public.markings_before_update() returns trigger
language plpgsql as $$
begin
  if new.overrides is distinct from old.overrides then
    new.auto := public.apply_overrides(new.auto, new.overrides);
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists markings_before_update on public.markings;
create trigger markings_before_update before update on public.markings
  for each row execute function public.markings_before_update();

-- When the tutor enters or edits an answer key, re-mark every submission for that task.
create or replace function public.task_key_changed() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.key is distinct from old.key or new.auto is distinct from old.auto then
    for r in select student_id from public.submissions where task_id = new.task_id and status = 'submitted' loop
      perform public.refresh_auto(r.student_id, new.task_id);
    end loop;
  end if;
  return new;
end $$;

drop trigger if exists task_key_changed on public.task_private;
create trigger task_key_changed after update on public.task_private
  for each row execute function public.task_key_changed();

-- Students may write their corrections, but never the tutor's review fields.
create or replace function public.corrections_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_tutor() then
    if tg_op = 'INSERT' then
      new.reviewed := false; new.tutor_comment := null;
    else
      new.reviewed := old.reviewed; new.tutor_comment := old.tutor_comment;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists corrections_guard on public.corrections;
create trigger corrections_guard before insert or update on public.corrections
  for each row execute function public.corrections_guard();

-- ─────────────────────────────── RPC FUNCTIONS ────────────────────────

create or replace function public.day_list() returns table (day int, title text)
language sql stable security definer set search_path = public as $$
  select l.day, l.title from public.lessons l where auth.uid() is not null order by l.day;
$$;

create or replace function public.submit_task(p_task_id text, p_answers jsonb, p_meta jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_day int;
begin
  if auth.uid() is null then raise exception 'Please sign in again.'; end if;
  select day into v_day from public.task_private where task_id = p_task_id;
  if v_day is null then raise exception 'Unknown exercise: %', p_task_id; end if;
  if not exists (select 1 from public.day_access where student_id = auth.uid() and day = v_day) then
    raise exception 'Day % is locked.', v_day;
  end if;
  if exists (select 1 from public.submissions where student_id = auth.uid() and task_id = p_task_id and status = 'submitted') then
    raise exception 'This exercise has already been submitted.';
  end if;
  insert into public.submissions (student_id, day, task_id, answers, meta, status, submitted_at, updated_at)
  values (auth.uid(), v_day, p_task_id, coalesce(p_answers, '{}'::jsonb), coalesce(p_meta, '{}'::jsonb), 'submitted', now(), now())
  on conflict (student_id, task_id) do update
    set answers = excluded.answers, meta = excluded.meta, status = 'submitted', submitted_at = now(), updated_at = now();
  perform public.refresh_auto(auth.uid(), p_task_id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.start_listening(p_task_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_day int; v_script jsonb; v_allowed int; v_plays int;
begin
  if auth.uid() is null then raise exception 'Please sign in again.'; end if;
  select day, script, plays into v_day, v_script, v_allowed from public.task_private where task_id = p_task_id;
  if v_script is null then raise exception 'There is no recording for this exercise.'; end if;
  if public.is_tutor() then
    return jsonb_build_object('script', v_script, 'plays_left', null);
  end if;
  if not exists (select 1 from public.day_access where student_id = auth.uid() and day = v_day) then
    raise exception 'Day % is locked.', v_day;
  end if;
  if exists (select 1 from public.submissions where student_id = auth.uid() and task_id = p_task_id and status = 'submitted') then
    raise exception 'You have already submitted this exercise.';
  end if;
  select plays into v_plays from public.listening_plays where student_id = auth.uid() and task_id = p_task_id;
  if coalesce(v_plays, 0) >= v_allowed then
    raise exception 'You have already played this recording. Ask your tutor to allow another play.';
  end if;
  insert into public.listening_plays as lp (student_id, task_id, plays, last_played_at)
  values (auth.uid(), p_task_id, 1, now())
  on conflict (student_id, task_id) do update set plays = lp.plays + 1, last_played_at = now();
  return jsonb_build_object('script', v_script, 'plays_left', v_allowed - coalesce(v_plays, 0) - 1);
end $$;

create or replace function public.release_day(p_student uuid, p_day int, p_release boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_tutor() then raise exception 'Only the tutor can release marking.'; end if;
  insert into public.day_reports (student_id, day) values (p_student, p_day) on conflict do nothing;
  update public.day_reports
     set released = p_release,
         released_at = case when p_release then now() else null end,
         updated_at = now()
   where student_id = p_student and day = p_day;
end $$;

create or replace function public.get_released_extras(p_day int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in again.'; end if;
  if not public.is_tutor() and not exists (
    select 1 from public.day_reports where student_id = auth.uid() and day = p_day and released
  ) then
    return '{}'::jsonb;
  end if;
  return coalesce((
    select jsonb_object_agg(task_id, jsonb_build_object('model', model, 'script', script, 'key', key))
      from public.task_private where day = p_day
  ), '{}'::jsonb);
end $$;

create or replace function public.tutor_set_password(p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_tutor() then raise exception 'Only the tutor can change passwords.'; end if;
  if char_length(coalesce(p_password, '')) < 8 then raise exception 'The password must be at least 8 characters.'; end if;
  if not exists (select 1 from public.profiles where id = p_user and role = 'student') then
    raise exception 'That account is not a student account.';
  end if;
  begin
    update auth.users
       set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
     where id = p_user;
  exception when insufficient_privilege then
    raise exception 'Supabase did not allow this change. Reset the password in Supabase → Authentication → Users instead.';
  end;
end $$;

-- ─────────────────────────────── SECURITY RULES (RLS) ─────────────────

alter table public.profiles        enable row level security;
alter table public.lessons         enable row level security;
alter table public.lesson_private  enable row level security;
alter table public.task_private    enable row level security;
alter table public.day_access      enable row level security;
alter table public.submissions     enable row level security;
alter table public.listening_plays enable row level security;
alter table public.markings        enable row level security;
alter table public.day_reports     enable row level security;
alter table public.corrections     enable row level security;
alter table public.tutor_notes     enable row level security;
alter table public.chat_messages   enable row level security;
alter table public.board_pages     enable row level security;
alter table public.board_items     enable row level security;
alter table public.classroom       enable row level security;

-- profiles
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or role = 'tutor' or public.is_tutor());
drop policy if exists profiles_tutor_update on public.profiles;
create policy profiles_tutor_update on public.profiles for update to authenticated
  using (public.is_tutor()) with check (public.is_tutor());

-- lessons: students read unlocked days only
drop policy if exists lessons_read on public.lessons;
create policy lessons_read on public.lessons for select to authenticated
  using (public.is_tutor() or exists (
    select 1 from public.day_access a where a.student_id = auth.uid() and a.day = lessons.day));

-- tutor-only tables
drop policy if exists lesson_private_tutor on public.lesson_private;
create policy lesson_private_tutor on public.lesson_private for all to authenticated
  using (public.is_tutor()) with check (public.is_tutor());
drop policy if exists task_private_tutor on public.task_private;
create policy task_private_tutor on public.task_private for all to authenticated
  using (public.is_tutor()) with check (public.is_tutor());
drop policy if exists tutor_notes_tutor on public.tutor_notes;
create policy tutor_notes_tutor on public.tutor_notes for all to authenticated
  using (public.is_tutor()) with check (public.is_tutor());

-- day access
drop policy if exists day_access_read on public.day_access;
create policy day_access_read on public.day_access for select to authenticated
  using (student_id = auth.uid() or public.is_tutor());
drop policy if exists day_access_tutor on public.day_access;
create policy day_access_tutor on public.day_access for all to authenticated
  using (public.is_tutor()) with check (public.is_tutor());

-- submissions: students save drafts for unlocked days; submitting goes through submit_task()
drop policy if exists submissions_read on public.submissions;
create policy submissions_read on public.submissions for select to authenticated
  using (student_id = auth.uid() or public.is_tutor());
drop policy if exists submissions_student_insert on public.submissions;
create policy submissions_student_insert on public.submissions for insert to authenticated
  with check (student_id = auth.uid() and status = 'draft' and exists (
    select 1 from public.day_access a where a.student_id = auth.uid() and a.day = submissions.day));
drop policy if exists submissions_student_update on public.submissions;
create policy submissions_student_update on public.submissions for update to authenticated
  using (student_id = auth.uid() and status = 'draft')
  with check (student_id = auth.uid() and status = 'draft');
drop policy if exists submissions_tutor on public.submissions;
create policy submissions_tutor on public.submissions for all to authenticated
  using (public.is_tutor()) with check (public.is_tutor());

-- listening plays
drop policy if exists plays_read on public.listening_plays;
create policy plays_read on public.listening_plays for select to authenticated
  using (student_id = auth.uid() or public.is_tutor());
drop policy if exists plays_tutor on public.listening_plays;
create policy plays_tutor on public.listening_plays for all to authenticated
  using (public.is_tutor()) with check (public.is_tutor());

-- markings and day reports: students only see them after the tutor releases the day
drop policy if exists markings_student_read on public.markings;
create policy markings_student_read on public.markings for select to authenticated
  using (student_id = auth.uid() and exists (
    select 1 from public.day_reports r where r.student_id = markings.student_id and r.day = markings.day and r.released));
drop policy if exists markings_tutor on public.markings;
create policy markings_tutor on public.markings for all to authenticated
  using (public.is_tutor()) with check (public.is_tutor());

drop policy if exists reports_student_read on public.day_reports;
create policy reports_student_read on public.day_reports for select to authenticated
  using (student_id = auth.uid() and released);
drop policy if exists reports_tutor on public.day_reports;
create policy reports_tutor on public.day_reports for all to authenticated
  using (public.is_tutor()) with check (public.is_tutor());

-- corrections
drop policy if exists corrections_read on public.corrections;
create policy corrections_read on public.corrections for select to authenticated
  using (student_id = auth.uid() or public.is_tutor());
drop policy if exists corrections_student_insert on public.corrections;
create policy corrections_student_insert on public.corrections for insert to authenticated
  with check (student_id = auth.uid() and exists (
    select 1 from public.day_reports r where r.student_id = auth.uid() and r.day = corrections.day and r.released));
drop policy if exists corrections_student_update on public.corrections;
create policy corrections_student_update on public.corrections for update to authenticated
  using (student_id = auth.uid() and not reviewed) with check (student_id = auth.uid());
drop policy if exists corrections_tutor on public.corrections;
create policy corrections_tutor on public.corrections for all to authenticated
  using (public.is_tutor()) with check (public.is_tutor());

-- chat
drop policy if exists chat_read on public.chat_messages;
create policy chat_read on public.chat_messages for select to authenticated using (true);
drop policy if exists chat_insert on public.chat_messages;
create policy chat_insert on public.chat_messages for insert to authenticated with check (sender_id = auth.uid());
drop policy if exists chat_tutor_delete on public.chat_messages;
create policy chat_tutor_delete on public.chat_messages for delete to authenticated using (public.is_tutor());

-- whiteboard
drop policy if exists pages_read on public.board_pages;
create policy pages_read on public.board_pages for select to authenticated using (true);
drop policy if exists pages_write on public.board_pages;
create policy pages_write on public.board_pages for insert to authenticated with check (true);
drop policy if exists pages_update on public.board_pages;
create policy pages_update on public.board_pages for update to authenticated using (true) with check (true);
drop policy if exists pages_delete on public.board_pages;
create policy pages_delete on public.board_pages for delete to authenticated using (public.is_tutor());
drop policy if exists items_all on public.board_items;
create policy items_all on public.board_items for all to authenticated using (true) with check (true);

-- classroom
drop policy if exists classroom_read on public.classroom;
create policy classroom_read on public.classroom for select to authenticated using (true);
drop policy if exists classroom_tutor on public.classroom;
create policy classroom_tutor on public.classroom for update to authenticated
  using (public.is_tutor()) with check (public.is_tutor());

-- ─────────────────────────────── PERMISSIONS ──────────────────────────

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on all tables in schema public from anon;

do $$
declare f text;
begin
  foreach f in array array[
    'public.is_tutor()', 'public.day_list()', 'public.submit_task(text, jsonb, jsonb)', 'public.start_listening(text)',
    'public.release_day(uuid, int, boolean)', 'public.get_released_extras(int)', 'public.tutor_set_password(uuid, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.refresh_auto(uuid, text)', 'public.handle_new_user()', 'public.handle_new_profile()',
    'public.task_key_changed()', 'public.corrections_guard()'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- ─────────────────────────────── RECORDINGS STORAGE ───────────────────

do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit)
  values ('recordings', 'recordings', false, 26214400)
  on conflict (id) do nothing;

  drop policy if exists "ielts recordings upload" on storage.objects;
  create policy "ielts recordings upload" on storage.objects for insert to authenticated
    with check (bucket_id = 'recordings' and (storage.foldername(name))[1] = auth.uid()::text);
  drop policy if exists "ielts recordings update" on storage.objects;
  create policy "ielts recordings update" on storage.objects for update to authenticated
    using (bucket_id = 'recordings' and (storage.foldername(name))[1] = auth.uid()::text);
  drop policy if exists "ielts recordings read" on storage.objects;
  create policy "ielts recordings read" on storage.objects for select to authenticated
    using (bucket_id = 'recordings' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_tutor()));
  drop policy if exists "ielts recordings delete" on storage.objects;
  create policy "ielts recordings delete" on storage.objects for delete to authenticated
    using (bucket_id = 'recordings' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_tutor()));
exception when others then
  raise notice 'Could not set up recordings storage (%).', sqlerrm;
end $$;

-- ─────────────────────────────── LIVE UPDATES ─────────────────────────

do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime' and not puballtables) then
    foreach t in array array['chat_messages', 'submissions', 'day_access', 'day_reports', 'corrections', 'markings'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
exception when others then
  raise notice 'Could not turn on live updates (%).', sqlerrm;
end $$;

-- ─────────────────────────────── STARTING DATA ────────────────────────

insert into public.classroom (id) values (1) on conflict (id) do nothing;
insert into public.board_pages (id, title, sort) values ('page-1', 'Page 1', 1) on conflict (id) do nothing;



-- ─────────────────────────────── LESSON CONTENT (14 days) ─────────────


insert into public.lessons (day, title, data) values (1, $ielts$Orientation and Diagnostic$ielts$, $ielts${"goals":["Understand the full IELTS Academic format and timings","Set a baseline for Listening, Writing and Speaking","Set up the error log and vocabulary notebook"],"timing":"Format walkthrough 30 min · Listening 40 min · Writing 60 min · Speaking 40 min · Reading 30 min · Set-up 15 min","lesson":[{"h":"The IELTS Academic test at a glance"},{"table":{"head":["Paper","Time","Questions","What it tests"],"rows":[["Listening","About 30 min","40 (4 parts)","Part 1 everyday conversation · Part 2 monologue on a public topic · Part 3 academic discussion (2–4 speakers) · Part 4 academic lecture"],["Reading","60 min","40 (3 passages)","Long academic texts with question types such as True/False/Not Given, matching headings, summary and sentence completion"],["Writing","60 min","2 tasks","Task 1: describe a chart, table, process or map (150+ words, ~20 min) · Task 2: essay (250+ words, ~40 min, double weight)"],["Speaking","11–14 min","3 parts","Part 1 familiar topics · Part 2 talk for up to 2 minutes from a cue card · Part 3 deeper discussion"]]}},{"list":["Listening is heard ONCE only.","Each paper gets a band from 0 to 9 in half bands.","The overall band is the average of the four papers."]},{"h":"Your starting point (EF SET)"},{"table":{"head":["Skill","EF SET","Level","Indicative IELTS"],"rows":[["Reading","73","C2","7.5 – 8.0"],["Listening","54","B2","5.5 – 6.0"],["Writing","59","B2","6.0"],["Speaking","55","B2","5.5 – 6.0"]]}},{"p":"Reading is already a strength. Most of our time goes to Listening, Writing and Speaking. The target is 6.5 overall with no skill below 6.0."},{"h":"Set-up: error log and vocabulary notebook"},{"list":["Error log: every wrong answer is recorded with the question type and the reason (spelling, distractor, missed paraphrase, ran out of time). The site builds this for you from your marked work.","Vocabulary notebook: word · meaning · collocation · your own example sentence. Use the Flashcards page to revise."]}],"tasks":[{"id":"d1-l1","kind":"listening","title":"Listening diagnostic: Library Registration (Part 1)","intro":"Complete the form. Write ONE WORD AND/OR A NUMBER for each answer. You will hear the recording ONCE.","preview":30,"groups":[{"heading":"LIBRARY REGISTRATION FORM","type":"text","qs":[["1","Type of membership: ___"],["2","Surname: ___"],["3","Date of birth: ___ March 2003"],["4","Address: ___ Riverside Road"],["5","Postcode: ___"],["6","Phone number: ___"],["7","Fee paid: £___"],["8","Maximum number of books at one time: ___"],["9","Free computer use: ___ per day"],["10","New Sunday opening hours: 11 am to ___"]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":0},{"id":"d1-w1","kind":"writing","task":2,"title":"Writing diagnostic (Task 2)","minutes":40,"minWords":250,"prompt":"Some people believe that university education should be free for all students. To what extent do you agree or disagree?","tail":"Give reasons for your answer and include any relevant examples from your own knowledge or experience. Write at least 250 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d1-s1","kind":"speaking","part":1,"title":"Speaking baseline (Part 1)","intro":"Answer each question naturally, as in the real test. Press “Next question” when you finish each answer. Don’t worry about mistakes. This is just to see where you are starting from.","sets":[{"topic":"Hometown","qs":["Where are you from?","What do you like most about your hometown?","Has it changed much in recent years?"]},{"topic":"Studies / work","qs":["Do you work or are you a student?","Why did you choose that subject or job?","What would you like to do in the future?"]},{"topic":"Free time","qs":["What do you usually do at weekends?","Do you prefer spending free time alone or with others?"]},{"topic":"Technology","qs":["How often do you use your phone?","Which app do you use most, and why?"]}],"maxSeconds":420,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d1-r1","kind":"reading","title":"Reading check: Drones in Farming","minutes":15,"passage":{"title":"Drones in Farming","paras":["For centuries, farmers have relied on walking their fields to check the health of their crops. Over the past decade, however, small unmanned aircraft, commonly known as drones, have become an increasingly common sight above farmland in many parts of the world.","The most widespread use is crop monitoring. A drone fitted with a standard camera can photograph a large field in minutes, a task that might take a farm worker several hours on foot. More advanced models carry multispectral sensors, which record light that is invisible to the human eye. Because healthy plants reflect light differently from stressed ones, these images can reveal problems such as disease or a lack of water before they become visible from the ground.","Drones are also used for spraying. Rather than treating an entire field, a drone can apply fertiliser or pesticide only to the areas that need it. Supporters argue that this reduces both costs and environmental damage, although critics point out that spraying drones carry small loads and must be refilled frequently.","Despite these benefits, several obstacles remain. Battery life is the most commonly cited limitation: many agricultural drones can fly for less than thirty minutes before needing to land. In addition, the images they collect are only useful if someone can interpret them, which means farmers may need training or the help of specialist companies. Finally, in many countries operators must hold a licence and follow strict rules about where and how high they may fly.","For small-scale farmers, cost is often the deciding factor. Some have responded by sharing equipment through cooperatives, while others pay service providers to survey their land a few times each season."]},"groups":[{"text":"Questions 1–3: Answer with NO MORE THAN TWO WORDS from the passage.","type":"text","qs":[["1","What kind of sensors can detect plant stress that is invisible to the eye?"],["2","What is the most commonly mentioned limitation of agricultural drones?"],["3","Through what do some small-scale farmers share equipment?"]]},{"text":"Questions 4–6: Do the statements agree with the information in the passage?","type":"tfng","qs":[["4","A drone can photograph a large field faster than a worker on foot."],["5","Multispectral images show problems only after they are visible from the ground."],["6","Most small-scale farmers in the world now own a drone."]]},{"text":"Question 7: Choose the correct letter.","type":"choice","qs":[["7","The writer’s main purpose is to",["A  persuade farmers to buy drones","B  describe the uses and limitations of drones in farming","C  compare different drone brands"]]]}],"hasModel":false,"hasScript":false,"autoMarked":true}],"vocab":[["monitor","to watch or check something over time","monitor progress"],["limitation","something that restricts or reduces","a major limitation"],["interpret","to explain the meaning of","interpret data"],["cite","to mention as an example or reason","commonly cited"],["reluctant","unwilling","reluctant to change"],["affordable","cheap enough to buy","affordable housing"],["access","the right or chance to use something","have access to"],["significant","large or important","a significant increase"]],"homework":["Read “What examiners look for” on the Progress page and note anything unclear.","Write 10 sentences about yourself (studies, plans, hometown) to prepare for Speaking Part 1.","Finish any exercise you didn’t complete in class."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (1, $ielts$[{"after":2,"text":"Explain that Listening is heard ONCE only. Each paper gets a band from 0 to 9 in half bands, and the overall band is the average of the four."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d1-l1$ielts$, 1, $ielts$listening$ielts$, true, $ielts${"1":["visitor"],"2":["okoro"],"3":["14","14th","fourteenth","fourteen"],"4":["27","twenty-seven"],"5":["RB4 7TN"],"6":["0794 553 8126"],"7":["8","8.00","eight"],"8":["4","four"],"9":["1 hour","one hour","an hour","1 hr","1"],"10":["4","4 pm","4pm","four","four pm","4.00","4:00","4:00 pm","4.00 pm","4 o’clock","four o’clock","16:00"]}$ielts$::jsonb, $ielts$["LIBRARIAN: Good morning, welcome to the Central Library. How can I help?","STUDENT: Hi, I’d like to register for a library card, please.","LIBRARIAN: Of course. Are you a student at the university?","STUDENT: No, I’m doing a short English course at the language centre nearby.","LIBRARIAN: Then you’ll need our Visitor membership. Can I have your full name?","STUDENT: Yes, it’s Daniel Okoro. That’s O-K-O-R-O.","LIBRARIAN: Thank you. And your date of birth?","STUDENT: The fourteenth of March, two thousand and three.","LIBRARIAN: And where are you staying at the moment?","STUDENT: At 27 Riverside Road.","LIBRARIAN: Do you know the postcode?","STUDENT: Yes, it’s R-B-4, 7-T-N.","LIBRARIAN: And a phone number?","STUDENT: It’s oh-seven-nine-four, double five three, eight-one-two-six.","LIBRARIAN: Lovely. Visitor membership is fifteen pounds for a year, or eight pounds for six months.","STUDENT: I’m only here for five months, so the six-month option, please.","LIBRARIAN: Fine. With visitor membership you can borrow up to four books at a time, for three weeks.","STUDENT: Can I use the computers as well?","LIBRARIAN: Yes, they’re free for one hour per day. You just need to book at the front desk.","STUDENT: And what time do you close?","LIBRARIAN: Eight o’clock Monday to Friday and five on Saturdays. We used to be closed on Sundays, but from next month we’ll open from eleven until four.","STUDENT: That’s great, thank you."]$ielts$::jsonb, null, $ielts$This is the baseline. Do not help during the recording. Afterwards, look at which answers were lost to spelling and which to distractors (e.g. £15 vs £8 for the fee).$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d1-w1$ielts$, 1, $ielts$writing$ielts$, false, null, null, null, $ielts$Do not help during the 40 minutes. This essay is the baseline for comparison on Day 14.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d1-s1$ielts$, 1, $ielts$speaking$ielts$, false, null, null, null, $ielts$Do not correct him yet. Listen for fluency, range of vocabulary, grammar and pronunciation.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d1-r1$ielts$, 1, $ielts$reading$ielts$, true, $ielts${"1":["multispectral sensors","multispectral"],"2":["battery life"],"3":["cooperatives","co-operatives"],"4":["TRUE"],"5":["FALSE"],"6":["NOT GIVEN"],"7":["B"]}$ielts$::jsonb, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (2, $ielts$Listening Part 1 · Task 1 Line Graphs · Extending Part 1 Answers · True/False/Not Given$ielts$, $ielts${"goals":["Handle form completion with names, numbers and spelling","Write a Task 1 report with a clear overview","Extend Part 1 answers to 2–3 sentences","Tell FALSE apart from NOT GIVEN"],"timing":"Listening 60 min · Writing 70 min · Speaking 45 min · Reading 30 min · Review 15 min","lesson":[{"h":"Listening Part 1: what catches people out"},{"list":["Names and postcodes are spelt out letter by letter, so write exactly what you hear.","Numbers: “double five” = 55; “oh” = 0.","Speakers often change or correct an answer: wait for the final version.","Several prices or times may be mentioned before the right one."]},{"h":"Writing Task 1: the four-paragraph structure"},{"table":{"head":["Paragraph","What to write"],"rows":[["1. Introduction","Paraphrase the title in one sentence (what, where, when). Do not copy it word for word."],["2. Overview","Two or three main trends with NO numbers. This is the most important paragraph for the band score."],["3. Body 1","Details and figures for one group of data."],["4. Body 2","Details and figures for the rest, with comparisons."]]}},{"h":"Useful language for trends"},{"table":{"head":["Going up","Going down","No change / other"],"rows":[["rose, increased, grew, climbed","fell, decreased, declined, dropped","remained stable, levelled off"],["a sharp / steady / slight rise","a dramatic / gradual fall","fluctuated, peaked at, hit a low of"],["doubled, more than tripled","halved","overtook, surpassed"]]}},{"h":"Speaking Part 1: extending answers"},{"tip":"Answer + Reason + Example/detail. Aim for 2–3 sentences, about 20 seconds."},{"tip":"Weak: “Yes, I like music.”\nBetter: “Yes, I really enjoy music, especially Afrobeats, because it helps me relax after a long day. I usually listen to it on my way home or while I’m studying.”"},{"h":"Reading: True / False / Not Given"},{"tip":"TRUE: the passage says the same thing (often in different words).\nFALSE: the passage says the opposite.\nNOT GIVEN: the passage does not say enough to decide. Do not use outside knowledge."},{"p":"Watch the small words: most, all, always, only, never. “Common” does not mean “most”."}],"tasks":[{"id":"d2-l1","kind":"listening","title":"Warm-up: dictation drill","intro":"You will hear 12 items, once each. Write each one exactly. Spelling and numbers must be perfect.","preview":10,"itemPause":8,"announce":true,"groups":[{"type":"text","qs":[["1","Phone number: ___"],["2","Surname: ___"],["3","Address: ___"],["4","Date: ___"],["5","Price: ___"],["6","Postcode: ___"],["7","Time: ___"],["8","Surname: ___"],["9","Year: ___"],["10","Distance: ___"],["11","Percentage: ___"],["12","Street: ___"]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":12},{"id":"d2-l2","kind":"listening","title":"Listening: Joining a Sports Centre (Part 1)","intro":"Complete the notes. Write ONE WORD AND/OR A NUMBER for each answer. You will hear the recording ONCE.","preview":30,"groups":[{"heading":"FITLIFE SPORTS CENTRE: NEW MEMBER","type":"text","qs":[["1","Membership chosen: ___"],["2","Monthly cost: £___"],["3","Swimming pool: £___ per visit"],["4","Joining fee this month: £___"],["5","Name: Amara ___"],["6","Email: amara.b@___.net"],["7","Previous injury: ___"],["8","Induction day: ___"],["9","Induction time: ___"],["10","Trainer: ___"]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":0},{"id":"d2-w1","kind":"writing","task":1,"title":"Writing Task 1: line graph","minutes":20,"minWords":150,"prompt":"The graph below shows the number of international students enrolled at three universities between 2015 and 2025.","tail":"Summarise the information by selecting and reporting the main features, and make comparisons where relevant. Write at least 150 words.","img":"c_day2_line.png","chartData":"Line graph, international students (thousands), years 2015/2017/2019/2021/2023/2025. University A: 2.0, 2.5, 3.1, 3.8, 4.6, 5.5. University B: 4.0, 4.2, 4.1, 3.6, 3.2, 3.0. University C: 1.0, 1.2, 1.8, 2.9, 3.9, 4.4.","hasModel":true,"hasScript":false,"autoMarked":false},{"id":"d2-s1","kind":"speaking","part":1,"title":"Speaking Part 1: extending answers","intro":"Use Answer + Reason + Example. Aim for 2–3 sentences per question. Press “Next question” after each answer.","sets":[{"topic":"Weather","qs":["What’s the weather like where you live?","Do you prefer hot or cold weather?","Does the weather affect your mood?"]},{"topic":"Food","qs":["What’s your favourite meal?","Do you cook?","Is there any food you didn’t like as a child but enjoy now?"]},{"topic":"Music","qs":["What kind of music do you listen to?","Have you ever been to a live concert?","Did you learn a musical instrument at school?"]},{"topic":"Mobile phones","qs":["How long have you had your current phone?","What do you use it for most?","Could you live without it for a week?"]}],"maxSeconds":480,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d2-r1","kind":"reading","title":"Reading: Sleep and Memory (True/False/Not Given)","minutes":12,"passage":{"title":"Sleep and Memory","paras":["For a long time, sleep was viewed as a period of rest in which the brain was largely inactive. Research over the last century has shown that this view is mistaken. During sleep, the brain remains highly active, and much of this activity appears to support memory.","Sleep is divided into stages. Deep sleep, also known as slow-wave sleep, occurs mostly in the first half of the night and is thought to be particularly important for consolidating facts and information. Rapid eye movement (REM) sleep, in which most vivid dreaming occurs, becomes longer towards the morning and has been linked to emotional processing and creative problem-solving.","One explanation for sleep’s effect on memory is that the brain “replays” experiences from the day. In experiments with rats, patterns of brain activity recorded while the animals learned a maze were repeated while they slept.","For students, the implications are significant. Several studies have found that people who sleep after learning remember more than those who stay awake for the same length of time. Staying up all night before an exam, a habit common among students, may therefore be counterproductive. Even a short daytime nap has been shown to improve recall in some experiments, although the benefits seem to depend on the length of the nap.","Not all scientists agree on exactly how these processes work, and research continues. However, there is broad agreement that regular, sufficient sleep is one of the simplest ways to support learning."]},"groups":[{"text":"Questions 1–8: Do the statements agree with the information in the passage?","type":"tfng","qs":[["1","Scientists once believed the brain was mostly inactive during sleep."],["2","Deep sleep mainly happens in the second half of the night."],["3","REM sleep has been connected with creative problem-solving."],["4","The rat experiments were carried out at a university in the USA."],["5","People who sleep after learning tend to remember more than those who stay awake."],["6","Most students stay up all night before exams."],["7","Naps of any length improve memory."],["8","Scientists fully agree on how sleep improves memory."]]}],"hasModel":false,"hasScript":false,"autoMarked":true}],"vocab":[["enrolment","the number of people registered","student enrolment"],["decline","to become smaller or fewer","a steady decline"],["overtake","to go past","overtook University B"],["fluctuate","to go up and down","prices fluctuated"],["consolidate","to make stronger or more secure","consolidate learning"],["counterproductive","having the opposite effect to the one intended","counterproductive habit"],["implication","a possible effect or result","serious implications"],["steadily","gradually and evenly","rose steadily"]],"homework":["After your marking is released, rewrite your Task 1 answer using the feedback and underline your overview.","Learn the 12 trend expressions in the lesson table.","Finish any exercise you didn’t complete in class."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (2, $ielts$[{"after":1,"text":"In the sports centre recording, three prices are mentioned before the right one, and the joining fee needs a calculation (half of £25)."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d2-l1$ielts$, 2, $ielts$listening$ielts$, true, $ielts${"1":["0803 446 7712"],"2":["Fitzgerald"],"3":["15 Woodhouse Lane"],"4":["21 September","21st September","September 21","September 21st","21 Sept","21st Sept","the 21st of September","21/09","21/9"],"5":["£1,250","1250","1,250 pounds","£1250.00"],"6":["CB2 9QR"],"7":["7:45 pm","7.45 pm","7:45","7.45","19:45","19.45","quarter to eight","a quarter to eight","7:45pm"],"8":["Thompson"],"9":["1998"],"10":["3.5 km","3.5 kilometres","3.5 kilometers","three and a half kilometres"],"11":["40%","40 per cent","40 percent","forty per cent"],"12":["Harcourt Street","Harcourt St"]}$ielts$::jsonb, $ielts$[{"n":"1","lines":["Phone number: oh-eight-oh-three, double four six, seven-seven-one-two."]},{"n":"2","lines":["Surname: Fitzgerald. F-I-T-Z-G-E-R-A-L-D."]},{"n":"3","lines":["Address: 15 Woodhouse Lane."]},{"n":"4","lines":["Date: the twenty-first of September."]},{"n":"5","lines":["Price: one thousand two hundred and fifty pounds."]},{"n":"6","lines":["Postcode: C-B-2, 9-Q-R."]},{"n":"7","lines":["Time: a quarter to eight in the evening."]},{"n":"8","lines":["Surname: Thompson. T-H-O-M-P-S-O-N."]},{"n":"9","lines":["Year: nineteen ninety-eight."]},{"n":"10","lines":["Distance: three and a half kilometres."]},{"n":"11","lines":["Percentage: forty per cent."]},{"n":"12","lines":["Street: Harcourt Street. H-A-R-C-O-U-R-T."]}]$ielts$::jsonb, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d2-l2$ielts$, 2, $ielts$listening$ielts$, true, $ielts${"1":["Standard"],"2":["30","thirty"],"3":["4","four"],"4":["12.50","12.5"],"5":["Bello"],"6":["zipmail"],"7":["knee"],"8":["Saturday"],"9":["9:15","9.15","9:15 am","9.15 am","9.15am","quarter past nine"],"10":["Marcus"]}$ielts$::jsonb, $ielts$["RECEPTIONIST: Good afternoon, FitLife Sports Centre, Grace speaking.","CALLER: Hello, I’m calling about joining the gym.","RECEPTIONIST: Sure. We have three options. Standard is thirty pounds a month and gives you access from six in the morning until ten at night. Off-peak is twenty pounds, but only between ten and four on weekdays. And Premium is forty-five pounds, which includes classes and the swimming pool.","CALLER: I work during the day, so off-peak won’t work for me. Does Standard include the pool?","RECEPTIONIST: No, the pool comes with Premium only. Standard members can pay four pounds per visit.","CALLER: I only swim about once a week, so I’ll take Standard.","RECEPTIONIST: Lovely. There’s normally a joining fee of twenty-five pounds, but it’s half price this month.","CALLER: Great.","RECEPTIONIST: Can I take your name?","CALLER: Amara Bello. That’s B-E-L-L-O.","RECEPTIONIST: And an email address?","CALLER: It’s amara dot b, at zipmail, Z-I-P-M-A-I-L, dot net.","RECEPTIONIST: Any injuries or medical conditions our trainers should know about?","CALLER: I hurt my knee playing football last year, but it’s fine now.","RECEPTIONIST: I’ll note that. Your free induction session can be on Thursday at six-thirty or Saturday at nine-fifteen.","CALLER: Saturday, please.","RECEPTIONIST: Your trainer will be Marcus. And remember to bring a padlock for the lockers, or you can buy one here for three pounds."]$ielts$::jsonb, null, $ielts$Point out the distractors: three prices are mentioned before the right one, and the joining fee needs a calculation (half of £25). Part 1 answers are often changed or corrected mid-sentence.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d2-w1$ielts$, 2, $ielts$writing$ielts$, false, null, null, $ielts$["The line graph illustrates the number of international students enrolled at three universities between 2015 and 2025.","Overall, enrolment at Universities A and C grew steadily over the period, whereas University B saw a decline. By 2025, University A had the largest international student population.","In 2015, University B had the highest figure, at 4,000 students, compared with 2,000 at University A and just 1,000 at University C. Numbers at University B rose slightly to 4,200 in 2017 but then fell steadily, finishing the period at 3,000.","In contrast, University A grew consistently throughout the decade, overtaking University B around 2020 and reaching 5,500 by 2025. University C experienced the most dramatic change, with enrolment more than quadrupling to 4,400. Growth there was particularly rapid after 2019, and it had overtaken University B by 2023."]$ielts$::jsonb, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d2-s1$ielts$, 2, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d2-r1$ielts$, 2, $ielts$reading$ielts$, true, $ielts${"1":["TRUE"],"2":["FALSE"],"3":["TRUE"],"4":["NOT GIVEN"],"5":["TRUE"],"6":["NOT GIVEN"],"7":["FALSE"],"8":["FALSE"]}$ielts$::jsonb, null, null, $ielts$Question 6 is the key teaching point: “common” does not mean “most”. Small words like most, all, always, only and never decide many TFNG answers.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (3, $ielts$Listening Part 2 (Maps) · Task 1 Bar Charts and Tables · Speaking Part 2 · Matching Headings$ielts$, $ielts${"goals":["Follow directions to label a map","Compare data accurately in bar charts and tables","Use the one-minute preparation time in Part 2","Match headings to paragraphs by main idea"],"timing":"Listening 60 min · Writing 70 min · Speaking 45 min · Reading 30 min · Review 15 min","lesson":[{"h":"Map questions: direction language"},{"list":["on your left / right · opposite · beside · next to · just before · just past","the far side of · in the north-east corner · at the end of · between X and Y","Study the map for a minute before the audio starts: find the entrance and the compass."]},{"h":"Writing Task 1: language of comparison"},{"list":["X was higher/lower than Y · X was twice as high as Y · the highest/lowest figure was …","X accounted for / made up 40% of … · by contrast · whereas · while","the gap between X and Y narrowed/widened","Use precise verbs: rose by 44 percentage points (from 20% to 64%)."]},{"h":"Speaking Part 2: the cue card"},{"p":"You have 1 minute to make notes and must speak for 1–2 minutes. Write 3–4 key words for each bullet point, not sentences."},{"tip":"Structure: Opening line (what/who) → Bullet 1 → Bullet 2 → Bullet 3 → Final bullet (“explain why…”) with feeling or reflection. Use past tenses accurately for stories."},{"h":"Reading: matching headings"},{"tip":"Read the first and last sentences of each paragraph to find its MAIN idea. Ignore headings that only match a detail. There are always more headings than paragraphs."}],"tasks":[{"id":"d3-l1","kind":"listening","title":"Listening: Greenfield Park (Part 2, map)","intro":"Look at the map. You have time to study it before the recording starts. Answer the questions as you listen. You will hear the recording ONCE.","preview":45,"img":"c_day3_map.png","chartData":"Map of Greenfield Park (north at top). Main entrance at the bottom centre; main path runs north from the entrance to a lake in the centre; car park in the bottom-left corner. Labelled circles: A = just right (east) of the entrance; B = between the car park and the lake; C = far (north) side of the lake, opposite the entrance; D = east side of the lake; E = north-west corner; F = north-east corner; G = west side of the lake; H = right of the main path just before the lake.","groups":[{"text":"Questions 1–6: Label the map. Choose the correct letter, A–H.","type":"select","options":["A","B","C","D","E","F","G","H"],"qs":[["1","Visitor centre"],["2","Café"],["3","Picnic area"],["4","Children’s playground"],["5","Bird-watching hide"],["6","Rose garden"]]},{"text":"Questions 7–9: Choose the correct letter, A, B or C.","type":"choice","qs":[["7","In summer, the park closes at",["A  5 pm","B  7 pm","C  9 pm"]],["8","Dogs must be kept on a lead",["A  everywhere in the park","B  near the lake and in the playground","C  only in the car park"]],["9","Cycling is allowed",["A  on all paths","B  on the main path only","C  in the rose garden"]]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":0},{"id":"d3-w1","kind":"writing","task":1,"title":"Writing Task 1: bar chart","minutes":20,"minWords":150,"prompt":"The chart below shows the percentage of households with home internet access in four regions in 2010 and 2024.","tail":"Summarise the information by selecting and reporting the main features, and make comparisons where relevant. Write at least 150 words.","img":"c_day3_bar.png","chartData":"Bar chart, % of households with home internet access, 2010 vs 2024. North 35% → 78%; South 42% → 85%; East 20% → 64%; West 28% → 71%.","hasModel":true,"hasScript":false,"autoMarked":false},{"id":"d3-w2","kind":"writing","task":1,"homework":true,"title":"Homework Task 1: table","minutes":20,"minWords":150,"prompt":"The table shows the average number of hours per week spent on four leisure activities by different age groups.","tail":"Summarise the information by selecting and reporting the main features, and make comparisons where relevant. Write at least 150 words.","table":{"head":["Activity (hours/week)","16–24","25–44","45–64","65+"],"rows":[["Social media","18","12","7","3"],["Sport / exercise","6","4","3","2"],["Reading","2","3","5","8"],["Watching TV","8","10","14","21"]]},"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d3-s1","kind":"speaking","part":2,"title":"Speaking Part 2: cue cards","intro":"For each card you get 1 minute to make notes, then speak for up to 2 minutes. Try to keep talking until at least 1 minute 30 seconds.","cards":[{"topic":"Describe a teacher who influenced you.","bullets":["who this teacher was","what subject they taught","what they did that was special","and explain how they influenced you."]},{"topic":"Describe a place you would like to visit in the future.","bullets":["where it is","how you learned about it","what you would do there","and explain why you want to go there."]},{"topic":"Describe a piece of technology you use every day.","bullets":["what it is","when you started using it","what you use it for","and explain how your life would be different without it."]}],"prep":60,"maxSeconds":120,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d3-r1","kind":"reading","title":"Reading: Urban Farming (Matching headings)","minutes":15,"passage":{"title":"Urban Farming","paras":["A  Growing food in cities is not new. During wartime, many urban families grew vegetables in gardens and public parks to supplement limited supplies. What is new is the scale and variety of today’s urban farming projects, which range from rooftop gardens to large indoor facilities.","B  One of the most technologically advanced forms is vertical farming, in which crops are grown in stacked layers indoors under artificial light. Because temperature, light and water are all controlled, crops can be grown all year round, regardless of the weather outside.","C  Supporters highlight several benefits. Food grown close to where it is eaten needs less transport, which can reduce fuel use. Fresh produce can also reach consumers within hours of harvest, keeping more of its flavour.","D  However, urban farming has significant drawbacks. Indoor farms use large amounts of electricity for lighting and climate control, and several well-known companies have closed after failing to make a profit. Land in city centres is also expensive, limiting the space available for outdoor projects.","E  Beyond food production, community gardens can bring social benefits. Residents who might never otherwise meet work side by side, and schools use gardens to teach children where food comes from. For some participants, these social rewards matter more than the harvest itself."]},"groups":[{"text":"Questions 1–5: Choose the correct heading for paragraphs A–E.","type":"select","legend":["i   A long history with a modern twist","ii   Farming that ignores the seasons","iii   The rising cost of food in cities","iv   Shorter journeys and fresher food","v   Financial and energy challenges","vi   More than just a source of food","vii   Why governments ban rooftop farms","viii   The best crops for indoor farms"],"options":["i","ii","iii","iv","v","vi","vii","viii"],"qs":[["1","Paragraph A"],["2","Paragraph B"],["3","Paragraph C"],["4","Paragraph D"],["5","Paragraph E"]]},{"text":"Questions 6–7: Complete the sentences with ONE WORD from the passage.","type":"text","qs":[["6","In vertical farms, crops grow in stacked layers under ___ light."],["7","___ use community gardens to show children where food comes from."]]}],"hasModel":false,"hasScript":false,"autoMarked":true}],"vocab":[["opposite","directly facing","opposite the entrance"],["adjacent","next to","adjacent to the lake"],["account for","to form a part of a total","accounted for 40%"],["narrow (v)","to become smaller","the gap narrowed"],["supplement","to add to","supplement their income"],["drawback","a disadvantage","a major drawback"],["highlight","to draw attention to","highlight the benefits"],["regardless of","without being affected by","regardless of the weather"]],"homework":["Write the table task (Homework Task 1) in 20 minutes.","Learn 10 direction words and phrases used in map questions.","Finish any exercise you didn’t complete in class."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (3, $ielts$[{"after":3,"text":"For the internet access chart, a good overview mentions: (1) access rose sharply in every region; (2) the South had the highest level in both years; (3) the East started lowest but saw the largest increase (+44 points). Check that all figures quoted are accurate."},{"after":6,"text":"Time each talk. If he stops before 1 min 30 sec, ask a follow-up (“Can you tell me more about…?”) and note this as a fluency target."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d3-l1$ielts$, 3, $ielts$listening$ielts$, true, $ielts${"1":["A"],"2":["H"],"3":["G"],"4":["B"],"5":["C"],"6":["F"],"7":["C"],"8":["B"],"9":["B"]}$ielts$::jsonb, $ielts$["RANGER: Good morning, everyone, and welcome to Greenfield Park. I’m Tom, one of the park rangers. We’re standing at the main entrance, and you can see the car park on your left. Let me tell you where everything is.","RANGER: First, the visitor centre. It’s just to your right as you come through the main entrance, so you can’t miss it. That’s where you’ll find maps and the toilets.","RANGER: If you walk straight up the main path towards the lake, just before you reach the water, on the right-hand side, there’s the café.","RANGER: Many visitors bring their own lunch, and the picnic area is on the west side of the lake, right beside the water. People sometimes confuse it with the area between the car park and the lake, but that’s actually our new children’s playground, which opened last spring.","RANGER: For bird lovers, the bird-watching hide is on the far side of the lake, directly opposite where we’re standing now. It’s very quiet there, so please keep your voices down.","RANGER: Finally, the rose garden. It’s in the north-east corner of the park. Not the north-west corner, which is a wildflower meadow that’s closed to the public at the moment.","RANGER: A few rules. The park opens at seven every morning, and the gates close at sunset. In winter that’s about five o’clock, but in summer we stay open until nine. Dogs are welcome, but they must be on a lead near the lake and in the playground. And cycling is allowed on the main path only; we ask cyclists to get off and walk everywhere else."]$ielts$::jsonb, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d3-w1$ielts$, 3, $ielts$writing$ielts$, false, null, null, $ielts$["The bar chart compares the proportion of households with home internet access in four regions in 2010 and 2024.","Overall, internet access increased substantially in every region over the period. The South had the highest rate in both years, while the East, which started from the lowest base, recorded the largest rise.","In 2010, just over two fifths of households in the South (42%) had internet access, slightly more than in the North (35%). The figures for the West and the East were lower, at 28% and 20% respectively.","By 2024, access had roughly doubled or more everywhere. The South reached 85% and the North 78%, while the West climbed to 71%. The most dramatic change was in the East, where the figure more than tripled to 64%, a rise of 44 percentage points, narrowing the gap with the other regions."]$ielts$::jsonb, $ielts$A good overview mentions: (1) access rose sharply in every region; (2) the South had the highest level in both years; (3) the East started lowest but saw the largest increase (+44 points).$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d3-w2$ielts$, 3, $ielts$writing$ielts$, false, null, null, null, $ielts$Key features: social media and sport fall with age; reading and TV rise with age. Social media is the main activity for 16–24s (18 hrs); TV dominates for 65+ (21 hrs).$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d3-s1$ielts$, 3, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d3-r1$ielts$, 3, $ielts$reading$ielts$, true, $ielts${"1":["i"],"2":["ii"],"3":["iv"],"4":["v"],"5":["vi"],"6":["artificial"],"7":["schools"]}$ielts$::jsonb, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (4, $ielts$Listening Part 3 · Task 1 Processes · Speaking Part 2 Practice · Paraphrasing$ielts$, $ielts${"goals":["Follow a discussion between several speakers and avoid distractors","Describe a process using sequencing language and the passive","Speak for the full 2 minutes","Recognise and produce paraphrases"],"timing":"Listening 60 min · Writing 70 min · Speaking 45 min · Reading 30 min · Review 15 min","lesson":[{"h":"Listening Part 3: discussions"},{"list":["Two or three speakers discuss an academic topic, often a project or assignment.","Speakers often say one thing and then correct it. Wait for words like “actually”, “but”, “in fact”.","For “who will do what” questions, listen for the names and the verbs together."]},{"h":"Writing Task 1: processes"},{"list":["Sequencing: First, … Next, … After that, … Once …, … Finally, …","Use the passive voice: bottles are collected, the glass is crushed, the mixture is melted.","Overview: say how many stages there are and where the process starts and ends.","Do not give opinions or add stages that are not shown."]},{"h":"Paraphrasing"},{"p":"IELTS questions rarely use the same words as the passage or recording. Train yourself to recognise synonyms (increase → rise, important → essential) and changes of word form (beneficial → benefit)."}],"tasks":[{"id":"d4-l1","kind":"listening","title":"Listening: Student Project Discussion (Part 3)","intro":"Answer the questions as you listen. You will hear the recording ONCE.","preview":40,"groups":[{"text":"Questions 1–3: Choose the correct letter, A, B or C.","type":"choice","qs":[["1","How many schools are in the final study?",["A  5","B  12","C  20"]],["2","According to Ryan, the main problem schools face is",["A  installation cost","B  lack of maintenance","C  lack of government grants"]],["3","In how many schools do teachers use panel data in lessons?",["A  two","B  five","C  twelve"]]]},{"text":"Questions 4–6: Who will write each part? A = Ryan, B = Kemi, C = both students","type":"select","options":["A","B","C"],"qs":[["4","literature review"],["5","data analysis"],["6","recommendations"]]},{"text":"Questions 7–10: Complete the notes. Write ONE WORD AND/OR A NUMBER.","type":"text","qs":[["7","Draft deadline: ___ November"],["8","Final deadline: 3rd ___"],["9","Dr Shaw advises using fewer but ___ charts"],["10","Photos should go in the ___"]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":0},{"id":"d4-w1","kind":"writing","task":1,"title":"Writing Task 1: process diagram","minutes":20,"minWords":150,"prompt":"The diagram below shows how glass bottles are recycled.","tail":"Summarise the information by selecting and reporting the main features. Write at least 150 words.","img":"c_day4_process.png","chartData":"Process diagram, 9 stages: 1 bottles collected at bottle banks; 2 taken to recycling plant; 3 sorted by colour (clear, green, brown); 4 washed to remove labels and dirt; 5 crushed into small pieces (cullet); 6 mixed with sand, soda ash, limestone; 7 melted in furnace (about 1,500°C); 8 moulded into new bottles; 9 filled, labelled and sent to shops.","hasModel":true,"hasScript":false,"autoMarked":false},{"id":"d4-w2","kind":"writing","task":1,"homework":true,"title":"Homework Task 1: how tea is produced","minutes":20,"minWords":150,"prompt":"Describe the process of how tea is produced, from picking the leaves to packaging. Invent 6–8 logical stages (for example: picking, withering, rolling, drying, sorting, packaging) and describe them as if you were looking at a diagram.","tail":"Use sequencing words and the passive voice. Write at least 150 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d4-s1","kind":"speaking","part":2,"title":"Speaking Part 2: full 2-minute practice","intro":"For each card you get 1 minute to make notes, then speak for the full 2 minutes. Count how many times you say “em”, “like” or “you know”.","cards":[{"topic":"Describe a time you solved a difficult problem.","bullets":["what the problem was","when it happened","how you solved it","and explain how you felt afterwards."]},{"topic":"Describe a book or film that you enjoyed.","bullets":["what it was","when you read or watched it","what it was about","and explain why you enjoyed it."]},{"topic":"Describe a skill you would like to learn.","bullets":["what the skill is","how you would learn it","how long it would take","and explain why you want to learn it."]}],"prep":60,"maxSeconds":120,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d4-p1","kind":"drill","skill":"vocabulary","title":"Paraphrasing practice","intro":"Rewrite each sentence using the word in brackets. Keep the meaning the same.","items":[["1","The number of users increased sharply. (rise)"],["2","Many people cannot afford healthcare. (too expensive)"],["3","The government should fund public libraries. (responsibility)"],["4","Children learn languages more easily than adults. (difficult)"],["5","Pollution has a negative effect on health. (harmful)"],["6","Most students prefer studying online. (majority)"],["7","The project was cancelled because of a lack of money. (insufficient)"],["8","Exercise improves mental health. (beneficial)"],["9","Cities are becoming more crowded. (population)"],["10","It is important to save energy. (essential)"]],"hasModel":true,"hasScript":false,"autoMarked":false},{"id":"d4-r1","kind":"reading","title":"Reading: Solar Power at Home (sentence completion)","minutes":12,"passage":{"title":"Solar Power at Home","paras":["In many regions with an unreliable electricity supply, households are turning to small solar systems. A basic system consists of panels, which convert sunlight into electricity; a battery, which stores energy for use at night; and an inverter, which changes the stored power into a form that household appliances can use.","The price of solar panels has fallen dramatically over the past fifteen years, making systems affordable for many more families. However, batteries remain relatively expensive and usually need to be replaced after several years, which adds to the long-term cost.","Many owners report that the greatest advantage is reliability: lights, fans and phone chargers continue to work during power cuts. Some small businesses, such as barbers and tailors, say that solar power has allowed them to stay open for longer hours.","Experts advise buyers to calculate their daily energy needs before purchasing a system. A common mistake is buying too few panels for the number of appliances, which leaves batteries empty by evening. Regular cleaning of panels is also recommended, as dust can reduce their output."]},"groups":[{"text":"Questions 1–7: Complete the sentences with NO MORE THAN THREE WORDS from the passage.","type":"text","qs":[["1","The ___ stores energy so that it can be used at night."],["2","The ___ changes stored power into a form appliances can use."],["3","Batteries are expensive and must be ___ after several years."],["4","Owners say the main benefit is ___."],["5","Some small businesses can now stay open for ___."],["6","Before buying, people should calculate their ___."],["7","___ on the panels can reduce their output."]]}],"hasModel":false,"hasScript":false,"autoMarked":true}],"vocab":[["transport (v)","to carry from one place to another","transported to a plant"],["sort","to put into groups","sorted by colour"],["subsequently","after that","subsequently melted"],["approximately","about","approximately 1,500°C"],["convert","to change into another form","convert sunlight into electricity"],["reliability","the quality of working well every time","improve reliability"],["maintenance","keeping something in good condition","regular maintenance"],["output","the amount produced","reduce output"]],"homework":["Write the tea production task (Homework Task 1).","Paraphrase 5 sentences from today’s reading passage in your own words.","Re-record one cue card and aim for the full 2 minutes."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (4, $ielts$[{"after":1,"text":"Question 2 is a classic distractor: Ryan mentions cost first but then corrects himself."},{"after":5,"text":"Record each Part 2 talk. Play it back and ask him to count filler words (“em”, “like”, “you know”) and repeated words. Set a target to reduce them on Day 9."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d4-l1$ielts$, 4, $ielts$listening$ielts$, true, $ielts${"1":["B"],"2":["B"],"3":["A"],"4":["A"],"5":["B"],"6":["C"],"7":["20","20th","twentieth"],"8":["December","Dec"],"9":["clearer"],"10":["appendix"]}$ielts$::jsonb, $ielts$["DR SHAW: So, Kemi and Ryan, how’s the project on solar power in schools going?","KEMI: Quite well. We originally planned to survey twenty schools, but only twelve replied, so we’ve decided to focus on those in more depth.","RYAN: Yes, and we’ve already visited five of them.","DR SHAW: Good. What’s the main finding so far?","RYAN: I expected cost to be the biggest problem, but actually most head teachers said the installation was paid for by grants. The real issue is maintenance. Nobody is responsible for cleaning the panels or checking them.","KEMI: Right, and dust reduces the output quite a lot.","DR SHAW: Interesting. And are the students using the panels for learning?","KEMI: Only in two schools. In those, science teachers use the data from the panels in their lessons. That’s something we want to recommend more widely.","DR SHAW: How are you dividing the writing?","RYAN: I’ll do the literature review and the methodology. Kemi’s better with numbers, so she’s doing the data analysis.","KEMI: And we’ll write the recommendations together.","DR SHAW: Remind me of the deadline.","KEMI: The third of December. But you said we could hand in a draft by the twentieth of November for feedback.","DR SHAW: That’s right. One suggestion: your charts. Use fewer, but make them clearer. Three or four strong charts are better than ten weak ones.","RYAN: Should we include the photos we took?","DR SHAW: Yes, but put them in the appendix, not in the main text."]$ielts$::jsonb, null, $ielts$Question 2 is a classic distractor: Ryan mentions cost first but then corrects himself. Train him to wait for words like “actually”, “but”, “in fact”.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d4-w1$ielts$, 4, $ielts$writing$ielts$, false, null, null, $ielts$["The diagram illustrates the process by which used glass bottles are recycled to make new ones.","Overall, there are nine stages in the process, beginning with the collection of used bottles and ending with new bottles being delivered to shops.","First, used bottles are collected from bottle banks and transported to a recycling plant. There, they are sorted by colour into clear, green and brown glass, before being washed to remove labels and dirt. The clean glass is then crushed into small pieces known as cullet.","Next, the cullet is mixed with raw materials, namely sand, soda ash and limestone. This mixture is melted in a furnace at a temperature of approximately 1,500°C, after which the molten glass is moulded into new bottles. Finally, these bottles are filled, labelled and sent to shops."]$ielts$::jsonb, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d4-w2$ielts$, 4, $ielts$writing$ielts$, false, null, null, null, $ielts$Focus on sequencing language, the passive, and a clear overview (number of stages, start and end).$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d4-s1$ielts$, 4, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d4-p1$ielts$, 4, $ielts$drill$ielts$, false, null, null, $ielts${"1":"There was a sharp rise in the number of users.","2":"Healthcare is too expensive for many people.","3":"Funding public libraries should be the government’s responsibility.","4":"Adults find it more difficult to learn languages than children (do).","5":"Pollution is harmful to health.","6":"The majority of students prefer studying online.","7":"The project was cancelled due to insufficient funding / money.","8":"Exercise is beneficial for mental health.","9":"The population of cities is growing / increasing.","10":"Saving energy is essential."}$ielts$::jsonb, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d4-r1$ielts$, 4, $ielts$reading$ielts$, true, $ielts${"1":["battery"],"2":["inverter"],"3":["replaced"],"4":["reliability"],"5":["longer hours"],"6":["daily energy needs"],"7":["dust"]}$ielts$::jsonb, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (5, $ielts$Listening Part 4 (Lecture) · Task 2 Essay Types and Planning · Speaking Part 3 · Summary Completion$ielts$, $ielts${"goals":["Complete lecture notes by following signposting language","Identify the four Task 2 essay types and plan an essay in 5 minutes","Give developed opinions in Part 3","Complete summaries with words from a box"],"timing":"Listening 60 min · Writing 75 min · Speaking 45 min · Reading 30 min · Review 15 min","lesson":[{"h":"Listening Part 4: lectures"},{"list":["One speaker, no break in the middle. Follow the order of the notes.","Signposting tells you where you are: “The first is…”, “However…”, “Another strategy…”, “For instance…”.","Before listening, predict the type of word needed for each gap (noun, number, adjective)."]},{"h":"Writing Task 2: the four essay types"},{"table":{"head":["Essay type","How to recognise it","Structure"],"rows":[["Opinion","To what extent do you agree or disagree?","Intro with clear position · 2 body paragraphs supporting it (optional: 1 concession) · conclusion"],["Discussion","Discuss both views and give your opinion.","Intro · view 1 · view 2 · conclusion with your opinion (state it in the intro too)"],["Problem–solution","What are the causes/problems? What solutions can you suggest?","Intro · causes/problems · solutions (link each to a cause) · conclusion"],["Advantages–disadvantages","Do the advantages outweigh the disadvantages?","Intro with answer · advantages · disadvantages · conclusion that weighs them"]]}},{"h":"The 5-minute plan"},{"list":["Underline the key words and decide the essay type.","Write your position in one sentence.","Two main ideas, each with one explanation and one example.","Check: does every paragraph answer the actual question?"]},{"h":"Model essay (opinion)"},{"tip":"Some people think that children should start learning a foreign language at primary school rather than secondary school. To what extent do you agree or disagree?"},{"model":["It is often argued that children should begin studying a foreign language at primary school instead of waiting until secondary school. I strongly agree with this view, as an early start offers clear advantages for both learning and personal development.","The main reason is that young children tend to pick up pronunciation more naturally than older learners. Younger pupils are often less afraid of making mistakes, so they are more willing to speak and imitate new sounds. A child who starts at the age of seven, for example, will have had several years of practice by the time they reach secondary school, giving them a strong foundation for more advanced grammar and vocabulary.","In addition, learning a second language early can broaden children’s understanding of the world. Through songs, stories and simple conversations, pupils are introduced to other cultures at an age when they are naturally curious. This can encourage tolerance and make them more open to studying or working abroad later in life.","Some people argue that primary pupils should concentrate on mastering their first language and core subjects such as mathematics. While this concern is understandable, a foreign language does not need to take up a large part of the timetable. Two or three short lessons a week are usually enough to build interest and basic skills without affecting other subjects.","In conclusion, I believe the benefits of introducing foreign languages at primary level clearly outweigh the drawbacks, provided that lessons are well planned and suitable for young learners."]},{"h":"Speaking Part 3: developing answers (OREO)"},{"tip":"Opinion → Reason → Example → Outcome/Other view. Part 3 answers should be 4–6 sentences. Use phrases like “It depends on…”, “On the one hand…”, “In the long run…”."}],"tasks":[{"id":"d5-l1","kind":"listening","title":"Listening: Lecture on Habit Formation (Part 4)","intro":"Complete the notes. Write ONE WORD AND/OR A NUMBER for each answer. You will hear the lecture ONCE.","preview":45,"groups":[{"heading":"HOW HABITS ARE FORMED","type":"text","qs":[["1","A habit is a behaviour that has become ___"],["2","The habit loop: ___ (e.g. a time, a place or an emotion) → routine (the behaviour itself)"],["3","___ (makes the brain want to repeat the loop)"],["4","Popular claim: 21 days. UCL study: average of ___ days"],["5","Missing one day had little effect: ___ matters more than perfection"],["6","Strategy 1: habit ___ (linking a new habit to an existing one)"],["7","Strategy 2: change your ___"],["8","Example: put fruit on the kitchen ___ instead of in the fridge"],["9","Breaking bad habits: keep the cue and reward but replace the ___"],["10","Example: when bored, go for a short ___ instead of checking your phone"]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":0},{"id":"d5-p1","kind":"drill","skill":"writing","title":"Task 2 planning drill (5 minutes each)","intro":"For each question: name the essay type, write your position in one sentence, and list two main ideas with an example each. Plan only. Do not write the essays.","long":true,"items":[["1","Online learning will eventually replace traditional classrooms. To what extent do you agree or disagree?"],["2","Some people think the best way to reduce crime is to give longer prison sentences. Others believe there are better ways. Discuss both views and give your opinion."],["3","Many young people are unable to find jobs after finishing university. What are the causes of this, and what can be done about it?"],["4","More and more people are choosing to work from home. Do the advantages outweigh the disadvantages?"]],"hasModel":true,"hasScript":false,"autoMarked":false},{"id":"d5-w1","kind":"writing","task":2,"homework":true,"title":"Homework Task 2: online learning","minutes":40,"minWords":250,"prompt":"Online learning will eventually replace traditional classrooms. To what extent do you agree or disagree?","tail":"Give reasons for your answer and include any relevant examples from your own knowledge or experience. Write at least 250 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d5-s1","kind":"speaking","part":3,"title":"Speaking Part 3: developing answers","intro":"Use OREO: Opinion, Reason, Example, Outcome/Other view. Aim for 4–6 sentences per answer. Press “Next question” after each answer.","sets":[{"topic":"Education","qs":["Should schools teach practical skills such as cooking and money management?","Is it better to study at home or in a classroom?","How will education change in the next 20 years?"]},{"topic":"Technology","qs":["Has technology made people less sociable?","Should children be allowed to have smartphones?","Who benefits most from new technology, young or old people?"]},{"topic":"Teachers","qs":["What makes a good teacher?","Should teachers be paid more?","Can technology ever replace teachers?"]}],"maxSeconds":720,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d5-r1","kind":"reading","title":"Reading: The History of the Bicycle (summary completion)","minutes":12,"passage":{"title":"The History of the Bicycle","paras":["The earliest ancestor of the bicycle was built in Germany in 1817 by Karl Drais. Known as the “running machine”, it had two wheels and a seat but no pedals; riders moved forward by pushing their feet against the ground.","In the 1860s, inventors in France attached pedals directly to the front wheel. These machines were faster, but riding them on cobbled streets was so uncomfortable that they became known in English as “boneshakers”.","To increase speed, makers in the 1870s built machines with a very large front wheel and a small rear one. These high-wheelers, often called penny-farthings, were popular with young men but dangerous: riders sat high above the ground and could easily be thrown forward.","The breakthrough came in the 1880s with the “safety bicycle”. It had two wheels of similar size and a chain that connected the pedals to the rear wheel. In 1888, John Boyd Dunlop developed a practical air-filled tyre, which made cycling far more comfortable.","The safety bicycle quickly became popular. It was relatively cheap, and it gave many people, including women, a new sense of independence, allowing them to travel without relying on horses or trains."]},"groups":[{"text":"Complete the summary using words from the box. There are more words than gaps.","type":"text","wordbox":["pedals","front","dangerous","similar","chain","tyre","independence","engine","cheap","seat","brakes","different","comfortable","rear"],"qs":[["1","The first bicycle-like machine, built in 1817, had no ___ and was moved by pushing the feet along the ground."],["2","In the 1860s, pedals were attached to the ___ wheel."],["3","The high-wheelers of the 1870s were fast but ___."],["4","The safety bicycle of the 1880s had wheels of ___ size"],["5","and a ___ linking the pedals to the back wheel."],["6","Comfort improved with the invention of the air-filled ___."],["7","The bicycle also gave many people, including women, greater ___."]]}],"hasModel":false,"hasScript":false,"autoMarked":true}],"vocab":[["automatic","done without thinking","become automatic"],["trigger","something that causes an action","an emotional trigger"],["consistency","doing something the same way over time","consistency is key"],["outweigh","to be greater or more important than","the benefits outweigh the costs"],["tolerance","acceptance of different views or people","promote tolerance"],["broaden","to make wider","broaden your horizons"],["breakthrough","an important discovery","a major breakthrough"],["independence","freedom from control by others","a sense of independence"]],"homework":["Write the online learning essay (Homework Task 2) in 40 minutes.","Write the habit loop for one of your own habits (cue, routine, reward) in 5 sentences.","Finish any exercise you didn’t complete in class."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (5, $ielts$[]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d5-l1$ielts$, 5, $ielts$listening$ielts$, true, $ielts${"1":["automatic"],"2":["cue","the cue"],"3":["reward","the reward"],"4":["66","sixty-six"],"5":["consistency"],"6":["stacking"],"7":["environment"],"8":["table"],"9":["routine"],"10":["walk"]}$ielts$::jsonb, $ielts$["LECTURER: Today I’m going to talk about how habits are formed, and why they are so hard to break. A habit is a behaviour that has become automatic. In other words, we do it with very little conscious thought.","LECTURER: Researchers often describe habits as a loop with three parts. The first is the cue: a trigger that tells the brain to start the behaviour. This might be a time of day, a place, or an emotion such as boredom. The second part is the routine, which is the behaviour itself. And the third is the reward. The reward is what makes the brain want to repeat the loop in future.","LECTURER: So, how long does it take to form a habit? You may have heard the popular claim that it takes twenty-one days. However, a well-known study at University College London found that, on average, it took participants sixty-six days for a new behaviour to become automatic, and for some people it took much longer.","LECTURER: Interestingly, the same study found that missing a single day did not significantly affect the process. In other words, consistency matters more than perfection.","LECTURER: How can we use this? One effective strategy is called habit stacking: linking a new habit to one you already have. For example, “After I make my morning tea, I will read for ten minutes.” Another strategy is to change your environment. If you want to eat more fruit, put it on the kitchen table rather than in the fridge. Simply making it visible makes a big difference.","LECTURER: Breaking bad habits is harder. Rather than trying to remove a habit completely, it’s usually more effective to keep the same cue and reward, but replace the routine. For instance, someone who checks their phone whenever they feel bored could go for a short walk instead."]$ielts$::jsonb, null, $ielts$Part 4 has no break in the middle, so he must follow the order of the notes. Highlight the signposting phrases.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d5-p1$ielts$, 5, $ielts$drill$ielts$, false, null, null, $ielts${"1":"Opinion essay. Position stated clearly (agree / disagree / partly agree), two supported reasons, one concession.","2":"Discussion essay. One paragraph per view, own opinion in intro and conclusion.","3":"Problem–solution essay. Causes (e.g. skills mismatch, too few graduate jobs) each linked to a solution (e.g. internships, career guidance).","4":"Advantages–disadvantages essay. Clear answer to “outweigh?” in the intro, weighed in the conclusion."}$ielts$::jsonb, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d5-w1$ielts$, 5, $ielts$writing$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d5-s1$ielts$, 5, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d5-r1$ielts$, 5, $ielts$reading$ielts$, true, $ielts${"1":["pedals"],"2":["front"],"3":["dangerous"],"4":["similar"],"5":["chain"],"6":["tyre","tire"],"7":["independence"]}$ielts$::jsonb, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (6, $ielts$Full Skill Practice$ielts$, $ielts${"goals":["Complete each paper under timed conditions","Practise time management across a full test","Do a complete Speaking test with feedback"],"timing":"Listening 40 min · Reading 60 min · Writing 40 min · Speaking 20 min · Review 40 min","lesson":[{"h":"Today: full timed practice"},{"p":"Use one complete Listening test and one complete Academic Reading test from a Cambridge IELTS Academic practice book. Keep a different, unseen test for each mock day."},{"list":["Listening: do not pause the audio. Write your answers on the answer sheet as you listen.","Reading: strictly 60 minutes, with no extra time to transfer answers.","Writing: one full Task 2 essay in 40 minutes.","Speaking: a full Parts 1–3 mock."]}],"tasks":[{"id":"d6-ls","kind":"sheet","skill":"listening","title":"Full Listening test (Cambridge book)","count":40,"minutes":40,"intro":"Use an unseen Cambridge IELTS Academic Listening test. Play the audio from the book without pausing, and type your 40 answers here.","hasModel":false,"hasScript":false,"autoMarked":true},{"id":"d6-rs","kind":"sheet","skill":"reading","title":"Full Academic Reading test (Cambridge book)","count":40,"minutes":60,"intro":"Use an unseen Cambridge IELTS Academic Reading test. You have 60 minutes. Type your 40 answers here.","hasModel":false,"hasScript":false,"autoMarked":true},{"id":"d6-w1","kind":"writing","task":2,"title":"Writing Task 2: rural to urban migration","minutes":40,"minWords":250,"prompt":"In many countries, young people are leaving rural areas to live in cities. What problems does this cause? What solutions can you suggest?","tail":"Give reasons for your answer and include any relevant examples from your own knowledge or experience. Write at least 250 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d6-s1","kind":"speaking","part":1,"title":"Speaking mock (Set 1) · Part 1","intro":"Part 1 lasts 4–5 minutes. Answer in 2–3 sentences. Press “Next question” after each answer.","sets":[{"topic":"Hobbies","qs":["What do you enjoy doing in your free time?","How long have you had this hobby?","Is it a popular hobby in your country?"]},{"topic":"Shopping","qs":["Do you prefer shopping online or in shops?","When did you last buy something expensive?"]}],"maxSeconds":360,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d6-s2","kind":"speaking","part":2,"title":"Speaking mock (Set 1) · Part 2","intro":"You have 1 minute to make notes, then speak for 1–2 minutes.","cards":[{"topic":"Describe a festival or celebration that is important in your country.","bullets":["what the festival is","when it takes place","what people do during it","and explain why it is important."]}],"prep":60,"maxSeconds":120,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d6-s3","kind":"speaking","part":3,"title":"Speaking mock (Set 1) · Part 3","intro":"Part 3 lasts 4–5 minutes. Give developed answers (4–6 sentences).","sets":[{"topic":"Festivals and traditions","qs":["Why do people enjoy celebrating festivals?","Are traditional festivals becoming less important for young people? Why?","Should governments spend money on public celebrations?","How has globalisation affected local traditions?"]}],"maxSeconds":420,"hasModel":false,"hasScript":false,"autoMarked":false}],"vocab":[["migration","moving from one place to live in another","rural–urban migration"],["overcrowding","too many people in one place","serious overcrowding"],["infrastructure","basic systems such as roads and power","invest in infrastructure"],["incentive","something that encourages an action","tax incentives"],["ageing population","a population with more older people","cope with an ageing population"],["tradition","a custom passed down over time","preserve traditions"],["globalisation","the world becoming more connected","the effects of globalisation"],["heritage","culture and history passed down","cultural heritage"]],"homework":["After marking is released, review every wrong Listening and Reading answer and note why you got it wrong.","Rest well before tomorrow’s mock test."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (6, $ielts$[{"after":2,"text":"Note how long he spends on each Reading passage. If Passage 1 takes more than 20 minutes, practise moving on and coming back. Enter the book’s answer key on your marking page so the answer sheets mark themselves."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d6-ls$ielts$, 6, $ielts$sheet$ielts$, true, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d6-rs$ielts$, 6, $ielts$sheet$ielts$, true, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d6-w1$ielts$, 6, $ielts$writing$ielts$, false, null, null, null, $ielts$Check that problems cover BOTH rural areas (ageing population, labour shortages on farms) and cities (overcrowding, housing, unemployment), and that each solution clearly links to a problem.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d6-s1$ielts$, 6, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d6-s2$ielts$, 6, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d6-s3$ielts$, 6, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (7, $ielts$MOCK TEST 1$ielts$, $ielts${"goals":["Sit a complete IELTS Academic test under exam conditions","Get a reliable band for each skill","Identify priorities for Week 2"],"timing":"Listening 40 min · Reading 60 min · Writing 60 min · Speaking 15 min · Marking and feedback 60 min","lesson":[{"h":"Exam conditions"},{"list":["Quiet room, phone on silent, no breaks between Listening, Reading and Writing.","Spelling counts. Check plurals and capital letters.","Use a Cambridge IELTS Academic test you have not seen before for Listening and Reading."]}],"tasks":[{"id":"d7-ls","kind":"sheet","skill":"listening","title":"Mock 1: Listening (Cambridge book)","count":40,"minutes":40,"intro":"Unseen Cambridge IELTS Academic Listening test. Play the audio once without pausing and type your 40 answers here.","hasModel":false,"hasScript":false,"autoMarked":true},{"id":"d7-rs","kind":"sheet","skill":"reading","title":"Mock 1: Academic Reading (Cambridge book)","count":40,"minutes":60,"intro":"Unseen Cambridge IELTS Academic Reading test. 60 minutes. Type your 40 answers here.","hasModel":false,"hasScript":false,"autoMarked":true},{"id":"d7-w1","kind":"writing","task":1,"title":"Mock 1: Writing Task 1 (table)","minutes":20,"minWords":150,"prompt":"The table below shows the percentage of household waste recycled in four cities in 2005, 2015 and 2025.","tail":"Summarise the information by selecting and reporting the main features, and make comparisons where relevant. Write at least 150 words.","table":{"head":["City","2005","2015","2025"],"rows":[["Northport","12%","28%","45%"],["Eastfield","20%","25%","30%"],["Lakeview","8%","30%","52%"],["Westbury","25%","22%","26%"]]},"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d7-w2","kind":"writing","task":2,"title":"Mock 1: Writing Task 2","minutes":40,"minWords":250,"prompt":"Some people believe that governments should spend money on space exploration, while others think this money should be spent on solving problems on Earth. Discuss both views and give your own opinion.","tail":"Give reasons for your answer and include any relevant examples from your own knowledge or experience. Write at least 250 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d7-s1","kind":"speaking","part":1,"title":"Mock 1: Speaking Part 1","intro":"Answer in 2–3 sentences. Press “Next question” after each answer.","sets":[{"topic":"Where you live","qs":["Where do you live now?","Do you like the area?","What would you change about it?"]},{"topic":"Reading","qs":["Do you like reading?","What did you read as a child?","Do you prefer printed books or e-books?"]},{"topic":"Transport","qs":["How do you usually travel around your city?","Is public transport good where you live?"]}],"maxSeconds":420,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d7-s2","kind":"speaking","part":2,"title":"Mock 1: Speaking Part 2","intro":"You have 1 minute to make notes, then speak for 1–2 minutes.","cards":[{"topic":"Describe an important decision you made.","bullets":["what the decision was","when you made it","who helped you decide","and explain why it was important."]}],"prep":60,"maxSeconds":120,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d7-s3","kind":"speaking","part":3,"title":"Mock 1: Speaking Part 3","intro":"Give developed answers (4–6 sentences).","sets":[{"topic":"Decisions","qs":["Do young people today have to make more decisions than in the past?","Should parents make important decisions for their children?","Why do some people find it difficult to make decisions?","Is it better to make decisions quickly or slowly?"]}],"maxSeconds":420,"hasModel":false,"hasScript":false,"autoMarked":false}],"vocab":[["exploration","travelling to discover new places","space exploration"],["allocate","to give for a particular purpose","allocate funds"],["priority","something more important than others","a top priority"],["innovation","a new idea or method","technological innovation"],["justify","to show something is reasonable","justify the cost"],["substantial","large in amount","substantial investment"],["comparatively","when compared with others","comparatively low"],["remain","to stay the same","remained stable"]],"homework":["None today. Rest and review the mock results tomorrow."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (7, $ielts$[{"after":1,"text":"Task 1 key features: Lakeview rose most (8% → 52%) and was highest in 2025; Northport also improved strongly; Eastfield grew slowly; Westbury stayed roughly the same (around 22–26%) and went from highest in 2005 to lowest in 2025."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d7-ls$ielts$, 7, $ielts$sheet$ielts$, true, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d7-rs$ielts$, 7, $ielts$sheet$ielts$, true, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d7-w1$ielts$, 7, $ielts$writing$ielts$, false, null, null, null, $ielts$Key features: Lakeview rose most (8% → 52%) and was highest in 2025; Northport also improved strongly; Eastfield grew slowly; Westbury stayed roughly the same and went from highest in 2005 to lowest in 2025.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d7-w2$ielts$, 7, $ielts$writing$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d7-s1$ielts$, 7, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d7-s2$ielts$, 7, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d7-s3$ielts$, 7, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (8, $ielts$Mock 1 Review · Distractors · Rewriting · Pronunciation$ielts$, $ielts${"goals":["Find patterns in Mock 1 mistakes","Catch corrections and distractors in Listening","Improve Writing using feedback","Work on word stress, sentence stress and clear sounds"],"timing":"Error analysis 45 min · Listening 45 min · Writing 60 min · Speaking 45 min · Review 15 min","lesson":[{"h":"Error analysis"},{"p":"Go through every mistake from Mock 1 together (your Error Log page lists them) and count them by type."},{"table":{"head":["Error type","Fix"],"rows":[["Spelling / plural / format","Daily dictation; check every answer for -s and capital letters"],["Fell for a distractor","Wait for the final answer; listen for “actually”, “but”, “no, sorry”"],["Missed a paraphrase","Paraphrase bank; predict synonyms before listening/reading"],["Ran out of time","Strict 20 minutes per Reading passage; skip and return"],["TFNG / YNNG confusion","Re-do the Day 2 exercise; focus on qualifiers (most, all, only)"],["Word limit exceeded","Read the instruction twice; count words"]]}},{"h":"Pronunciation"},{"p":"Word stress (stressed syllable in capitals):"},{"table":{"head":["Word","Word","Word"],"rows":[["PHO-to-graph","pho-TOG-ra-phy","pho-to-GRAPH-ic"],["e-CON-o-my","e-co-NOM-ic","de-VEL-op-ment"],["en-VI-ron-ment","tech-NOL-o-gy","ed-u-CA-tion"],["COM-fort-a-ble","in-ter-NA-tion-al","a-NAL-y-sis"]]}},{"p":"Minimal pairs: say both words clearly."},{"tip":"ship / sheep · live / leave · full / fool · think / sink · three / tree · walk / work · law / low · bad / bed"},{"p":"Sentence stress and chunking: pause at each slash and stress the capitalised words."},{"tip":"In my opinion, / the MAIN reason / is that young people / want BETTER opportunities / in the CITY."}],"tasks":[{"id":"d8-l1","kind":"listening","title":"Listening: distractor drill","intro":"You will hear 8 short dialogues, once each. Write ONE WORD AND/OR A NUMBER for each answer. Listen for the FINAL answer.","preview":15,"itemPause":6,"announce":true,"groups":[{"type":"text","qs":[["1","Day of the meeting: ___"],["2","Room number: ___"],["3","Student ticket price: £___"],["4","How will she travel? By ___"],["5","Name: ___"],["6","Number of chairs needed: ___"],["7","Arrival time: ___"],["8","Speaker B’s preferred colour: ___"]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":8},{"id":"d8-w1","kind":"writing","task":1,"title":"Rewrite Mock 1 Task 1","minutes":25,"minWords":150,"ref":"d7-w1","prompt":"Rewrite your Mock 1 Task 1 answer (shown below) using your feedback. Focus on a clear overview and accurate figures.","table":{"head":["City","2005","2015","2025"],"rows":[["Northport","12%","28%","45%"],["Eastfield","20%","25%","30%"],["Lakeview","8%","30%","52%"],["Westbury","25%","22%","26%"]]},"tail":"Write at least 150 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d8-w2","kind":"writing","task":2,"title":"Rewrite one Mock 1 Task 2 paragraph","minutes":20,"minWords":80,"ref":"d7-w2","prompt":"Choose one body paragraph from your Mock 1 Task 2 essay (shown below). Rewrite it with a clear topic sentence, an explanation and a specific example.","tail":"Write one complete paragraph (about 80–120 words).","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d8-s1","kind":"speaking","part":0,"title":"Pronunciation: read aloud","intro":"Read the text below aloud, clearly and at a natural pace. Pay attention to word stress and pausing at the slashes.","read":"photograph, photography, photographic. economy, economic, development. environment, technology, education. comfortable, international, analysis.\n\nship, sheep. live, leave. full, fool. think, sink. three, tree. walk, work. law, low. bad, bed.\n\nIn my opinion, / the MAIN reason / is that young people / want BETTER opportunities / in the CITY.","maxSeconds":180,"hasModel":false,"hasScript":false,"autoMarked":false}],"vocab":[["distractor","a wrong option meant to mislead","avoid distractors"],["analyse","to examine in detail","analyse mistakes"],["pattern","a regular way something happens","a clear pattern"],["accurate","correct in every detail","accurate figures"],["revise","to change in order to improve","revise an essay"],["emphasis","special importance","put emphasis on"],["clarity","being clear","improve clarity"],["intonation","the rise and fall of the voice","natural intonation"]],"homework":["Read the minimal pairs and word-stress table aloud twice.","Finish both Writing rewrites.","Write down your top 3 error types to watch for this week."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (8, $ielts$[{"after":9,"text":"Pronunciation is 25% of the Speaking score. Focus on being clear and natural, not on changing his accent."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d8-l1$ielts$, 8, $ielts$listening$ielts$, true, $ielts${"1":["Thursday"],"2":["40","forty"],"3":["9","nine","9.00"],"4":["car"],"5":["Kathryn"],"6":["15","fifteen"],"7":["9:15","9.15","9:15 am","9.15 am","quarter past nine"],"8":["green"]}$ielts$::jsonb, $ielts$[{"n":"1","lines":["A: When’s the meeting?","B: It’s on Tuesday. Oh no, wait, they’ve moved it to Thursday."]},{"n":"2","lines":["A: Which room?","B: Room fourteen. Sorry, I mean forty. Four, zero."]},{"n":"3","lines":["A: How much are the tickets?","B: Twelve pounds, but students get three pounds off."]},{"n":"4","lines":["A: Are you taking the bus?","B: I was going to, but my brother’s driving me there in his car now."]},{"n":"5","lines":["A: Her name’s Catherine?","B: Yes, but it’s spelt with a K. K-A-T-H-R-Y-N."]},{"n":"6","lines":["A: We need twenty chairs.","B: Actually, five people have cancelled."]},{"n":"7","lines":["A: It starts at half past nine.","B: Yes, but we have to arrive fifteen minutes early to register."]},{"n":"8","lines":["A: Most people choose the blue one.","B: True, but personally I prefer the green."]}]$ielts$::jsonb, null, $ielts$Each item has a correction or calculation. After marking, re-do the weakest Listening section from Mock 1 without looking at the answers.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d8-w1$ielts$, 8, $ielts$writing$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d8-w2$ielts$, 8, $ielts$writing$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d8-s1$ielts$, 8, $ielts$speaking$ielts$, false, null, null, null, $ielts$Tutor marks pronunciation from the recording. The transcript shows which words the computer recognised, which is a rough guide to clarity.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (9, $ielts$Multiple Choice and Matching · Task 2 Problem–Solution and Advantages–Disadvantages · Part 2 Fluency · Yes/No/Not Given$ielts$, $ielts${"goals":["Handle matching and multiple-choice under time pressure","Write the two remaining Task 2 types","Reduce fillers and keep going for 2 minutes","Identify the writer’s views"],"timing":"Listening 60 min · Writing 75 min · Speaking 45 min · Reading 30 min · Review 15 min","lesson":[{"h":"Matching tasks"},{"list":["There are always more options than questions, so some options are never used.","Listen for the reason or opinion, not the person’s job or a word you recognise."]},{"h":"Model essay (advantages–disadvantages)"},{"tip":"In many countries, more people are choosing to study online rather than attend classes in person. Do the advantages of this development outweigh the disadvantages?"},{"model":["In recent years, a growing number of students have chosen online courses over traditional classroom learning. In my view, although online study has some drawbacks, its advantages are greater for most learners.","The most significant benefit of online learning is flexibility. Students can watch lectures and complete tasks at times that suit them, which allows people with jobs or family responsibilities to gain qualifications they could not otherwise pursue. In addition, online courses are often cheaper, since learners save on transport and accommodation. A student in a small town, for instance, can follow a course offered by a university hundreds of kilometres away without having to relocate.","On the other hand, studying online has clear disadvantages. Without regular face-to-face contact, some students find it hard to stay motivated and may fall behind. Online learners also miss the informal discussions with classmates and lecturers that help to deepen understanding. Moreover, a reliable internet connection is essential, and this is not available to everyone.","Nevertheless, many of these problems can be reduced. Well-designed courses include live sessions and discussion groups, and learners can develop the self-discipline needed to manage their time effectively.","In conclusion, while online study requires motivation and good internet access, the flexibility and lower cost it offers mean that, for most people, its advantages outweigh its disadvantages."]},{"h":"Speaking Part 2: fluency"},{"p":"Target: fewer fillers than on Day 4. If you lose your way, use a recovery phrase: “What I mean is…”, “Let me put it another way…”, “Going back to…”."},{"h":"Reading: Yes / No / Not Given"},{"tip":"YES / NO / NOT GIVEN asks about the WRITER’S OPINION, not facts. Look for opinion signals: “In my view”, “I believe”, “It seems likely”."}],"tasks":[{"id":"d9-l1","kind":"listening","title":"Listening: Radio Interview (Part 2)","intro":"Answer the questions as you listen. You will hear the recording ONCE.","preview":45,"groups":[{"text":"Questions 1–3: Choose the correct letter, A, B or C.","type":"choice","qs":[["1","When did Read Together start?",["A  four years ago","B  eight years ago","C  fifteen years ago"]],["2","How many schools are involved now?",["A  eight","B  fifteen","C  120"]],["3","How often does each volunteer meet the children?",["A  twice a week","B  once a week","C  once a term"]]]},{"text":"Questions 4–7: What does each volunteer say about the programme? Choose from A–E.","type":"select","legend":["A  wanted to stay busy after retiring","B  enjoys watching children become more confident","C  hopes it will help their future career","D  felt anxious at the beginning","E  joined because a friend recommended it"],"options":["A","B","C","D","E"],"qs":[["4","Mr Bassey"],["5","Ngozi"],["6","Mrs Harris"],["7","David"]]},{"text":"Questions 8–10: Write ONE WORD for each answer.","type":"text","qs":[["8","Before starting, volunteers attend a ___ workshop."],["9","The biggest challenge is funding for ___."],["10","The plan is to open a lending ___ in each school."]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":0},{"id":"d9-w1","kind":"writing","task":2,"title":"Writing Task 2: traffic congestion (problem–solution)","minutes":40,"minWords":250,"prompt":"Traffic congestion is a growing problem in many cities. What are the main causes of this problem, and what solutions can you suggest?","tail":"Give reasons for your answer and include any relevant examples from your own knowledge or experience. Write at least 250 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d9-s1","kind":"speaking","part":2,"title":"Speaking Part 2: fluency practice","intro":"For each card you get 1 minute to make notes, then speak for the full 2 minutes. Use recovery phrases instead of stopping.","cards":[{"topic":"Describe a person you know who is very good at their job.","bullets":["who the person is","what their job is","what makes them good at it","and explain how you feel about this person."]},{"topic":"Describe a time when you were late for something important.","bullets":["what the event was","why you were late","what happened as a result","and explain how you felt about it."]},{"topic":"Describe a website or app that you use often.","bullets":["what it is","how you found it","what you use it for","and explain why it is useful to you."]}],"prep":60,"maxSeconds":120,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d9-r1","kind":"reading","title":"Reading: Working from Home (Yes/No/Not Given and matching information)","minutes":20,"passage":{"title":"Working from Home: What Have We Learned?","paras":["The rapid shift to remote work in recent years has been described as one of the largest workplace experiments in history. Now that many organisations have settled into new patterns, it is worth asking what has really been learned.","A  The most obvious benefit for employees is the end of the daily commute. Time once spent in traffic can be used for rest, exercise or family. In my view, this alone explains why so many workers are reluctant to return to the office full-time.","B  Productivity is more difficult to judge. Some surveys suggest that people working at home complete more tasks, while others indicate that collaboration and creativity suffer when colleagues rarely meet. I believe both findings can be true: routine tasks may benefit from quiet, while complex problem-solving often benefits from face-to-face discussion.","C  Remote work also creates new problems. Many employees report difficulty switching off, as the boundary between work and home becomes blurred. Younger workers, in particular, may miss out on the informal learning that comes from watching experienced colleagues.","D  For employers, the picture is mixed. Reduced office space can lower costs, but managers must find new ways to build trust and team spirit. Companies that simply moved their old office habits online, such as long daily meetings, have often struggled.","E  It seems likely that hybrid arrangements, combining office and home working, will become the norm for many office-based jobs. The challenge is to design them deliberately, rather than allowing them to develop by accident."]},"groups":[{"text":"Questions 1–5: Do the statements agree with the views of the writer?","type":"ynng","qs":[["1","Avoiding the commute is a major reason workers do not want to return to the office full-time."],["2","People working from home always complete more tasks than office workers."],["3","Complex problem-solving often benefits from meeting in person."],["4","Older workers find remote work more stressful than younger workers."],["5","Hybrid working is likely to become common in many office jobs."]]},{"text":"Questions 6–9: Which paragraph (A–E) contains the following information?","type":"select","options":["A","B","C","D","E"],"qs":[["6","a problem that particularly affects less experienced staff"],["7","a financial advantage for companies"],["8","a suggestion that hybrid working should be planned carefully"],["9","evidence from different surveys that seems to conflict"]]}],"hasModel":false,"hasScript":false,"autoMarked":true}],"vocab":[["congestion","too much traffic","traffic congestion"],["flexibility","the ability to change easily","greater flexibility"],["relocate","to move to a new place","relocate for work"],["self-discipline","the ability to control yourself","requires self-discipline"],["productivity","the rate of useful work done","boost productivity"],["collaboration","working together","encourage collaboration"],["boundary","a dividing line","blurred boundaries"],["deliberately","on purpose, with planning","designed deliberately"]],"homework":["Finish the traffic congestion essay if you didn’t complete it in class.","Write 5 sentences giving your own opinion on remote work, using opinion phrases."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (9, $ielts$[{"after":1,"text":"In the radio interview, option E is never used. Mrs Harris’s job (bakery) has nothing to do with the answer; he must listen for the reason, not the job."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d9-l1$ielts$, 9, $ielts$listening$ielts$, true, $ielts${"1":["A"],"2":["B"],"3":["B"],"4":["A"],"5":["C"],"6":["B"],"7":["D"],"8":["half-day","half day"],"9":["books"],"10":["library"]}$ielts$::jsonb, $ielts$["PRESENTER: My guest today is Funmi Adeyemi, coordinator of the Read Together programme. Funmi, how did it start?","FUNMI: It began four years ago, when a group of retired teachers noticed that many children in our area were leaving primary school without confident reading skills. We started with eight volunteers in one school. Today we have over a hundred and twenty volunteers in fifteen schools.","PRESENTER: What does a volunteer actually do?","FUNMI: Each volunteer meets the same two children once a week for forty-five minutes. They read together, talk about the story and play word games.","PRESENTER: Who are your volunteers?","FUNMI: All sorts of people. Mr Bassey is a retired engineer; he told me he joined because he wanted to stay active and use his time well. Ngozi is a university student, and for her it’s mainly about gaining experience, because she wants to become a teacher. Mrs Harris runs a bakery, and she says what she loves most is seeing the children’s confidence grow week by week. And then there’s David, who works in a bank. He admits he was nervous at first, because he’d never worked with children, but now he says it’s the highlight of his week.","PRESENTER: What training do volunteers get?","FUNMI: A half-day workshop before they start, and then a check-in session every term.","PRESENTER: And what’s next?","FUNMI: Our biggest challenge is funding for books. We’re hoping to open a small lending library in each school by next year."]$ielts$::jsonb, null, $ielts$Option E is never used. Note that Mrs Harris’s job (bakery) has nothing to do with the answer; he must listen for the reason, not the job.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d9-w1$ielts$, 9, $ielts$writing$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d9-s1$ielts$, 9, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d9-r1$ielts$, 9, $ielts$reading$ielts$, true, $ielts${"1":["YES"],"2":["NO"],"3":["YES"],"4":["NOT GIVEN"],"5":["YES"],"6":["C"],"7":["D"],"8":["E"],"9":["B"]}$ielts$::jsonb, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (10, $ielts$Full Timed Practice · Task 1 and Task 2 Together · Part 3 Abstract Topics$ielts$, $ielts${"goals":["Complete a full Writing paper in 60 minutes","Discuss abstract topics in Part 3","Build stamina with full Listening and Reading tests"],"timing":"Listening 40 min · Reading 60 min · Writing 60 min · Speaking 45 min · Review 15 min","lesson":[{"h":"Today: stamina and timing"},{"list":["One full Listening test and one full Academic Reading test from a Cambridge book (unseen).","Writing: Task 1 and Task 2 together in 60 minutes. If you tend to run out of time, start with Task 2."]},{"h":"Speaking Part 3: speculating"},{"p":"Part 3 asks about society and the future. Use speculation language: “It’s likely that…”, “I would imagine…”, “In the long term…”, “There’s a good chance that…”."}],"tasks":[{"id":"d10-ls","kind":"sheet","skill":"listening","title":"Full Listening test (Cambridge book)","count":40,"minutes":40,"intro":"Unseen Cambridge IELTS Academic Listening test. Play the audio once and type your 40 answers here.","hasModel":false,"hasScript":false,"autoMarked":true},{"id":"d10-rs","kind":"sheet","skill":"reading","title":"Full Academic Reading test (Cambridge book)","count":40,"minutes":60,"intro":"Unseen Cambridge IELTS Academic Reading test. 60 minutes. Type your 40 answers here.","hasModel":false,"hasScript":false,"autoMarked":true},{"id":"d10-w1","kind":"writing","task":1,"title":"Writing Task 1: energy line graph","minutes":20,"minWords":150,"prompt":"The graph below shows the share of electricity generated from four sources in Country X between 2000 and 2025.","tail":"Summarise the information by selecting and reporting the main features, and make comparisons where relevant. Write at least 150 words.","img":"c_day10_line.png","chartData":"Line graph, % of electricity by source, years 2000/2005/2010/2015/2020/2025. Coal: 62, 60, 55, 45, 34, 25. Gas: 25, 28, 30, 32, 30, 28. Solar: 0, 1, 4, 9, 17, 27. Wind: 2, 3, 6, 10, 15, 18.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d10-w2","kind":"writing","task":2,"title":"Writing Task 2: technology","minutes":40,"minWords":250,"prompt":"Some people think that modern technology has made our lives more complicated. To what extent do you agree or disagree?","tail":"Give reasons for your answer and include any relevant examples from your own knowledge or experience. Write at least 250 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d10-s1","kind":"speaking","part":3,"title":"Speaking Part 3: abstract topics","intro":"Give 4–6 sentence answers. Use speculation language. Press “Next question” after each answer.","sets":[{"topic":"Environment","qs":["Whose responsibility is it to protect the environment, individuals or governments?","Will people ever stop using cars?","Is climate change mainly a problem for rich or poor countries?"]},{"topic":"Work","qs":["Is job satisfaction more important than salary?","How will artificial intelligence change the job market?","Should people retire at a fixed age?"]},{"topic":"Cities","qs":["What are the advantages of living in a big city?","Why do some people move back to the countryside?","How could cities be made more pleasant to live in?"]},{"topic":"Health","qs":["Why do many people find it hard to live healthily?","Should junk food be taxed?","Is it the government’s job to make people healthier?"]}],"maxSeconds":900,"hasModel":false,"hasScript":false,"autoMarked":false}],"vocab":[["renewable","able to be replaced naturally","renewable energy"],["generate","to produce","generate electricity"],["complicated","difficult to understand or deal with","more complicated"],["convenience","being easy and useful","for convenience"],["dependence","needing something","dependence on technology"],["speculate","to guess about the future","hard to speculate"],["sustainable","able to continue without harm","sustainable growth"],["job satisfaction","feeling happy in your work","high job satisfaction"]],"homework":["After marking, rewrite your Task 1 overview until it clearly states 3 main trends.","Finish any exercise you didn’t complete in class."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (10, $ielts$[{"after":3,"text":"Task 1 key features: coal fell from 62% to 25%; solar rose from 0% to 27% and overtook coal in 2025; gas stayed fairly stable (25–32%); wind grew steadily to 18%."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d10-ls$ielts$, 10, $ielts$sheet$ielts$, true, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d10-rs$ielts$, 10, $ielts$sheet$ielts$, true, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d10-w1$ielts$, 10, $ielts$writing$ielts$, false, null, null, null, $ielts$Key features: coal fell from 62% to 25%; solar rose from 0% to 27% and overtook coal in 2025; gas stayed fairly stable (25–32%); wind grew steadily to 18%.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d10-w2$ielts$, 10, $ielts$writing$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d10-s1$ielts$, 10, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (11, $ielts$Accents and Spelling · Lecture Notes · Grammar Accuracy · Topic Vocabulary · Speed Reading$ielts$, $ielts${"goals":["Spell common IELTS words perfectly","Use complex grammar accurately","Build topic vocabulary for Speaking and Writing","Scan quickly for specific details"],"timing":"Listening 60 min · Grammar 60 min · Speaking 45 min · Reading 30 min · Review 15 min","lesson":[{"h":"Words people misspell in Listening"},{"tip":"accommodation · environment · government · necessary · temperature · Wednesday · February · library · restaurant · questionnaire · recommend · committee · guarantee · business · separate · schedule · conference · equipment · knowledge · occasionally"},{"h":"Topic vocabulary"},{"table":{"head":["Topic","Useful collocations"],"rows":[["Education","acquire knowledge · practical skills · rote learning · lifelong learning · academic pressure"],["Technology","cutting-edge · user-friendly · screen time · digital literacy · rely heavily on"],["Environment","carbon emissions · renewable energy · raise awareness · take action · waste disposal"],["Health","balanced diet · sedentary lifestyle · mental well-being · regular exercise · preventive care"],["Work","job security · work–life balance · career prospects · take on responsibility · earn a living"],["Travel","broaden horizons · off the beaten track · local customs · tourist attraction · culture shock"]]}},{"h":"Scanning"},{"list":["Scanning means looking for a specific detail (a name, a number, a date) without reading every word.","Decide what the answer will look like first: a year? a place? a material?","Move your eyes quickly down the passage until you see it, then read that sentence carefully."]}],"tasks":[{"id":"d11-l1","kind":"listening","title":"Spelling drill (20 words)","intro":"You will hear 20 words. Each word is said twice. Type each word with perfect spelling.","preview":5,"itemPause":6,"announce":true,"repeat":2,"groups":[{"type":"text","qs":[["1","___"],["2","___"],["3","___"],["4","___"],["5","___"],["6","___"],["7","___"],["8","___"],["9","___"],["10","___"],["11","___"],["12","___"],["13","___"],["14","___"],["15","___"],["16","___"],["17","___"],["18","___"],["19","___"],["20","___"]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":20},{"id":"d11-l2","kind":"listening","title":"Listening: Lecture on the History of Maps (Part 4)","intro":"Complete the notes. Write ONE WORD AND/OR A NUMBER for each answer. You will hear the lecture ONCE.","preview":45,"groups":[{"heading":"THE HISTORY OF MAPS","type":"text","qs":[["1","One early world map from Babylon was made of ___"],["2","It shows the world as a flat ___ surrounded by water"],["3","Eratosthenes measured the Earth using the angle of ___"],["4","Ptolemy used a grid of latitude and ___"],["5","In the 15th century, the ___ press made copying maps cheaper"],["6","Mercator’s map was published in ___"],["7","It was especially useful for ___"],["8","Weakness: it distorts ___ near the poles"],["9","Africa is about ___ times larger than Greenland"],["10","Modern maps rely on satellite data and ___"]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":0},{"id":"d11-g1","kind":"drill","skill":"grammar","title":"Grammar: find and correct the error","intro":"Each sentence has one grammar mistake. Write the corrected sentence.","items":[["1","The number of students have increased."],["2","There are many advantage of online learning."],["3","People who lives in cities often face stress."],["4","In the other hand, cars cause pollution."],["5","The graph shows the informations about energy use."],["6","It was rose sharply in 2010."],["7","Despite of the cost, many people buy cars."],["8","If the government invest more, the problem will reduce."],["9","Children should be encourage to read."],["10","The percentage of people who uses buses fell."],["11","Nowadays, technology play an important role."],["12","He suggested me to study harder."]],"hasModel":true,"hasScript":false,"autoMarked":false},{"id":"d11-g2","kind":"drill","skill":"grammar","title":"Grammar: combine the sentences","intro":"Combine each pair of sentences into one, using the word in brackets.","items":[["1","Online learning is flexible. It requires self-discipline. (although)"],["2","The city built a new bridge. It reduced traffic. (which)"],["3","People recycle more. Waste will decrease. (if)"],["4","Exercise improves health. It reduces stress. (not only … but also)"],["5","Coal use fell. Solar power grew. (whereas)"]],"hasModel":true,"hasScript":false,"autoMarked":false},{"id":"d11-s1","kind":"speaking","part":1,"title":"Speaking: topic vocabulary (1 minute per topic)","intro":"For each topic, speak for about 1 minute using at least three collocations from the topic vocabulary table in the lesson. Press “Next question” to move to the next topic.","sets":[{"topic":"Topic vocabulary","qs":["Education: talk about how you learn best.","Technology: talk about how technology affects your daily life.","Environment: talk about an environmental problem in your city.","Health: talk about how you try to stay healthy.","Work: talk about the job you want in the future.","Travel: talk about a place you have visited or want to visit."]}],"maxSeconds":480,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d11-r1","kind":"reading","title":"Reading: A Short History of Glass (scanning race, 5 minutes)","minutes":5,"passage":{"title":"A Short History of Glass","paras":["Glass is one of the oldest manufactured materials. The earliest known glass objects, mainly beads, date from around 3,500 BCE in Mesopotamia, in what is now Iraq. For centuries glass was rare and valuable, and it was used mostly for jewellery and small containers.","A major breakthrough came around the first century BCE, when craftsmen in the eastern Mediterranean discovered glassblowing. By blowing air through a tube into molten glass, workers could make thin, hollow vessels quickly and cheaply. The Romans spread the technique across their empire, and glass drinking vessels became common.","In the Middle Ages, coloured glass windows decorated cathedrals across Europe. Venice became famous for fine glass, and in 1291 the city’s glassmakers were moved to the island of Murano, partly because of the risk of fire.","Glass also changed science. Lenses made possible the microscope and the telescope, both developed around the start of the seventeenth century.","In the 1950s, Alastair Pilkington and Kenneth Bickerstaff developed the float glass process in Britain, in which molten glass is floated on a bath of molten tin to produce large, perfectly flat sheets. Most window glass today is still made this way. Modern glass is made mainly from sand, soda ash and limestone, and it can be recycled repeatedly without losing quality."]},"groups":[{"text":"Answer each question as quickly as you can, using words or numbers from the passage.","type":"text","qs":[["1","Where were the earliest known glass objects made?"],["2","What were these objects mainly?"],["3","When was glassblowing discovered?"],["4","Which people spread glassblowing across their empire?"],["5","In what year were Venice’s glassmakers moved to Murano?"],["6","Which two scientific instruments did lenses make possible?"],["7","What metal is used in the float glass process?"],["8","What are the three main raw materials of modern glass?"]]}],"hasModel":false,"hasScript":false,"autoMarked":true}],"vocab":[["distort","to change the shape or size of","distort the truth"],["projection","a way of showing the Earth on a flat surface","map projection"],["reproduce","to make a copy of","reproduce accurately"],["remarkable","unusual and impressive","remarkable accuracy"],["manufacture","to make in large amounts","manufactured goods"],["molten","melted by heat","molten glass"],["sedentary","involving a lot of sitting","sedentary lifestyle"],["awareness","knowledge of a situation","raise awareness"]],"homework":["Learn the 20 spelling words; there is a test at the start of Day 12.","Write 10 sentences using one collocation from each topic row.","Correct the grammar errors in one of your previous essays."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (11, $ielts$[]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d11-l1$ielts$, 11, $ielts$listening$ielts$, true, $ielts${"1":["accommodation"],"2":["environment"],"3":["government"],"4":["necessary"],"5":["temperature"],"6":["Wednesday"],"7":["February"],"8":["library"],"9":["restaurant"],"10":["questionnaire"],"11":["recommend"],"12":["committee"],"13":["guarantee"],"14":["business"],"15":["separate"],"16":["schedule"],"17":["conference"],"18":["equipment"],"19":["knowledge"],"20":["occasionally"]}$ielts$::jsonb, $ielts$[{"n":"1","lines":["accommodation."]},{"n":"2","lines":["environment."]},{"n":"3","lines":["government."]},{"n":"4","lines":["necessary."]},{"n":"5","lines":["temperature."]},{"n":"6","lines":["Wednesday."]},{"n":"7","lines":["February."]},{"n":"8","lines":["library."]},{"n":"9","lines":["restaurant."]},{"n":"10","lines":["questionnaire."]},{"n":"11","lines":["recommend."]},{"n":"12","lines":["committee."]},{"n":"13","lines":["guarantee."]},{"n":"14","lines":["business."]},{"n":"15","lines":["separate."]},{"n":"16","lines":["schedule."]},{"n":"17","lines":["conference."]},{"n":"18","lines":["equipment."]},{"n":"19","lines":["knowledge."]},{"n":"20","lines":["occasionally."]}]$ielts$::jsonb, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d11-l2$ielts$, 11, $ielts$listening$ielts$, true, $ielts${"1":["clay"],"2":["disc","disk"],"3":["shadows","shadow"],"4":["longitude"],"5":["printing"],"6":["1569"],"7":["sailors"],"8":["size"],"9":["14","fourteen"],"10":["GPS"]}$ielts$::jsonb, $ielts$["LECTURER: Maps are among the oldest forms of human communication. One of the earliest known maps of the world is a clay tablet from ancient Babylon. It shows the world as a flat disc surrounded by water.","LECTURER: The ancient Greeks made great advances. Eratosthenes, who worked in Egypt, calculated the size of the Earth with remarkable accuracy by comparing the angle of shadows in two different cities.","LECTURER: Later, in the second century, Ptolemy described how to locate places using a grid of latitude and longitude, an idea that is still central to mapmaking today.","LECTURER: For many centuries, maps had to be copied by hand, which was slow and led to errors. In the fifteenth century, however, the printing press allowed maps to be reproduced accurately and much more cheaply.","LECTURER: One of the most famous maps of all was published by Gerardus Mercator in 1569. His projection was especially useful for sailors, because a straight line on the map represented a constant compass direction. However, the Mercator projection distorts size, particularly near the poles. For example, Greenland appears similar in size to Africa, although Africa is actually about fourteen times larger.","LECTURER: Today, mapmaking depends on satellite data and GPS, which allow maps to be updated almost instantly."]$ielts$::jsonb, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d11-g1$ielts$, 11, $ielts$drill$ielts$, false, null, null, $ielts${"1":"The number of students has increased.","2":"There are many advantages of online learning.","3":"People who live in cities often face stress.","4":"On the other hand, cars cause pollution.","5":"The graph shows information about energy use.","6":"It rose sharply in 2010.","7":"Despite the cost / In spite of the cost, many people buy cars.","8":"If the government invests more, the problem will decrease / will be reduced.","9":"Children should be encouraged to read.","10":"The percentage of people who use buses fell.","11":"Nowadays, technology plays an important role.","12":"He suggested that I (should) study harder. / He suggested studying harder."}$ielts$::jsonb, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d11-g2$ielts$, 11, $ielts$drill$ielts$, false, null, null, $ielts${"1":"Although online learning is flexible, it requires self-discipline.","2":"The city built a new bridge, which reduced traffic.","3":"If people recycle more, waste will decrease.","4":"Exercise not only improves health but also reduces stress.","5":"Coal use fell, whereas solar power grew."}$ielts$::jsonb, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d11-s1$ielts$, 11, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d11-r1$ielts$, 11, $ielts$reading$ielts$, true, $ielts${"1":["Mesopotamia","Iraq","Mesopotamia (modern Iraq)","Mesopotamia, Iraq","in Mesopotamia"],"2":["beads"],"3":["first century BCE","around the first century BCE","1st century BCE","the first century BCE","around the 1st century BCE"],"4":["Romans","the Romans"],"5":["1291"],"6":["microscope and telescope","the microscope and the telescope","microscope and the telescope","telescope and microscope","the telescope and the microscope","microscopes and telescopes"],"7":["tin","molten tin"],"8":["sand, soda ash and limestone","sand, soda ash, limestone","sand soda ash limestone","sand, limestone and soda ash","soda ash, sand and limestone"]}$ielts$::jsonb, null, null, $ielts$Answers are auto-marked against a list of accepted forms. Check any marked wrong: the wording may still be acceptable.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (12, $ielts$Full Skill Practice · Pie Charts · Flow-Chart Completion$ielts$, $ielts${"goals":["Complete a second full timed Writing paper","Do a full Speaking mock with feedback","Practise diagram and flow-chart completion"],"timing":"Listening 40 min · Writing 60 min · Speaking 20 min · Reading 30 min · Feedback 45 min","lesson":[{"h":"Pie charts"},{"list":["Language for proportions: accounted for · made up · the largest proportion · a quarter / a fifth / just under half.","Compare the same category across the two charts, and say which category grew or shrank most."]},{"h":"Flow-chart completion"},{"list":["The flow chart follows the order of the passage.","Check the word limit and copy spellings exactly from the passage."]}],"tasks":[{"id":"d12-l0","kind":"listening","title":"Spelling test (10 words from Day 11)","intro":"You will hear 10 words from Day 11. Each word is said twice. Type each word with perfect spelling.","preview":5,"itemPause":6,"announce":true,"repeat":2,"groups":[{"type":"text","qs":[["1","___"],["2","___"],["3","___"],["4","___"],["5","___"],["6","___"],["7","___"],["8","___"],["9","___"],["10","___"]]}],"hasModel":false,"hasScript":true,"autoMarked":true,"scriptItems":10},{"id":"d12-ls","kind":"sheet","skill":"listening","title":"Full Listening test (Cambridge book)","count":40,"minutes":40,"intro":"Unseen Cambridge IELTS Academic Listening test. Play the audio once and type your 40 answers here.","hasModel":false,"hasScript":false,"autoMarked":true},{"id":"d12-w1","kind":"writing","task":1,"title":"Writing Task 1: pie charts","minutes":20,"minWords":150,"prompt":"The charts below show how students travelled to Hillside College in 2005 and 2025.","tail":"Summarise the information by selecting and reporting the main features, and make comparisons where relevant. Write at least 150 words.","img":"c_day12_pies.png","chartData":"Two pie charts, how students travel to Hillside College. 2005: car 40%, bus 30%, bicycle 5%, walking 15%, motorbike 10%. 2025: car 22%, bus 38%, bicycle 18%, walking 12%, motorbike 10%.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d12-w2","kind":"writing","task":2,"title":"Writing Task 2: public transport","minutes":40,"minWords":250,"prompt":"Governments should spend more money on public transport than on building new roads. To what extent do you agree or disagree?","tail":"Give reasons for your answer and include any relevant examples from your own knowledge or experience. Write at least 250 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d12-s1","kind":"speaking","part":1,"title":"Speaking mock (Set 3) · Part 1","intro":"Answer in 2–3 sentences. Press “Next question” after each answer.","sets":[{"topic":"Sport","qs":["Do you like sport?","Which sports are popular in your country?","Did you play sport at school?"]},{"topic":"Public transport","qs":["Do you often use public transport?","What do you do when you travel by bus?"]},{"topic":"Photos","qs":["Do you like taking photos?","What do you usually take photos of?"]}],"maxSeconds":420,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d12-s2","kind":"speaking","part":2,"title":"Speaking mock (Set 3) · Part 2","intro":"You have 1 minute to make notes, then speak for 1–2 minutes.","cards":[{"topic":"Describe a goal you hope to achieve in the next five years.","bullets":["what the goal is","why you set this goal","what you need to do to achieve it","and explain how you will feel if you achieve it."]}],"prep":60,"maxSeconds":120,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d12-s3","kind":"speaking","part":3,"title":"Speaking mock (Set 3) · Part 3","intro":"Give developed answers (4–6 sentences).","sets":[{"topic":"Goals and success","qs":["Why is it important for young people to set goals?","Do people today have more opportunities than their parents did?","Is success mainly the result of hard work or luck?","How do people’s goals change as they get older?"]}],"maxSeconds":420,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d12-r1","kind":"reading","title":"Reading: How Drinking Water Is Treated (flow chart)","minutes":12,"passage":{"title":"How Drinking Water Is Treated","paras":["Before water from rivers or reservoirs reaches our taps, it passes through several stages of treatment. First, the water is screened to remove large objects such as leaves, sticks and litter.","Next, chemicals called coagulants are added. These cause tiny particles of dirt to stick together, forming larger clumps known as floc. In the following stage, sedimentation, the water is left to stand in large tanks so that the heavy floc sinks to the bottom.","The clearer water then passes through filters made of layers of sand and gravel, and sometimes charcoal, which remove smaller particles as well as some unpleasant tastes and smells. After filtration, the water is disinfected, usually with chlorine, to kill any remaining bacteria and viruses. A small amount of chlorine is left in the water to keep it safe as it travels through pipes.","In some areas, fluoride is added to help prevent tooth decay, although this practice is debated. Finally, the treated water is stored in covered reservoirs or tanks before being pumped to homes and businesses."]},"groups":[{"text":"Complete the flow chart. Write ONE WORD ONLY from the passage.","type":"text","flow":true,"qs":[["1","Screening: removes leaves, sticks and ___"],["2","Coagulation: particles stick together to form ___"],["3","___: heavy clumps sink in large tanks"],["4","Filtration: layers of sand, ___ and sometimes charcoal"],["5","Disinfection: ___ kills bacteria and viruses"],["6","Optional: fluoride added to prevent tooth ___"],["7","Storage: in covered ___ or tanks"]]}],"hasModel":false,"hasScript":false,"autoMarked":true}],"vocab":[["proportion","a part of a whole","the largest proportion"],["commute (n)","a regular journey to work or study","a long commute"],["congested","too full of traffic","congested roads"],["invest","to spend money for future benefit","invest in transport"],["particle","a very small piece","dust particles"],["disinfect","to clean using chemicals to kill germs","disinfect the water"],["debate (v)","to discuss different opinions","widely debated"],["achieve","to succeed in doing","achieve a goal"]],"homework":["After your marking is released, write the pie chart task again in 18 minutes.","Review your whole Error Log from Days 1–12."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (12, $ielts$[{"after":1,"text":"Pie chart key features: car use nearly halved (40% → 22%); the bus became the most popular choice (38%); cycling more than tripled (5% → 18%); walking fell slightly; motorbike unchanged at 10%."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d12-l0$ielts$, 12, $ielts$listening$ielts$, true, $ielts${"1":["accommodation"],"2":["questionnaire"],"3":["Wednesday"],"4":["necessary"],"5":["committee"],"6":["guarantee"],"7":["separate"],"8":["environment"],"9":["recommend"],"10":["occasionally"]}$ielts$::jsonb, $ielts$[{"n":"1","lines":["accommodation."]},{"n":"2","lines":["questionnaire."]},{"n":"3","lines":["Wednesday."]},{"n":"4","lines":["necessary."]},{"n":"5","lines":["committee."]},{"n":"6","lines":["guarantee."]},{"n":"7","lines":["separate."]},{"n":"8","lines":["environment."]},{"n":"9","lines":["recommend."]},{"n":"10","lines":["occasionally."]}]$ielts$::jsonb, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d12-ls$ielts$, 12, $ielts$sheet$ielts$, true, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d12-w1$ielts$, 12, $ielts$writing$ielts$, false, null, null, null, $ielts$Key features: car use nearly halved (40% → 22%); the bus became the most popular choice (38%); cycling more than tripled (5% → 18%); walking fell slightly; motorbike unchanged at 10%.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d12-w2$ielts$, 12, $ielts$writing$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d12-s1$ielts$, 12, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d12-s2$ielts$, 12, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d12-s3$ielts$, 12, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d12-r1$ielts$, 12, $ielts$reading$ielts$, true, $ielts${"1":["litter"],"2":["floc"],"3":["sedimentation"],"4":["gravel"],"5":["chlorine"],"6":["decay"],"7":["reservoirs"]}$ielts$::jsonb, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (13, $ielts$Light Review and Rest$ielts$, $ielts${"goals":["Consolidate key language and strategies","Build confidence before the final mock","Rest"],"timing":"About 2 hours only","lesson":[{"h":"Final checklist"},{"table":{"head":["Paper","Remember"],"rows":[["Listening","Read ahead · predict word type · watch for corrections · check spelling and plurals · obey the word limit"],["Reading","20 minutes per passage · skim first, then scan · TFNG ≠ YNNG · never leave a blank"],["Task 1","Paraphrase the title · overview with no numbers · accurate figures · 150+ words · 20 minutes"],["Task 2","5-minute plan · clear position · topic sentence + explanation + example · 250+ words · 40 minutes"],["Speaking","Part 1: 2–3 sentences · Part 2: use all bullets, speak 2 minutes · Part 3: OREO, 4–6 sentences"]]}},{"h":"Light practice"},{"list":["One Listening section (Part 3 or 4) from an unseen Cambridge test.","One cue card from earlier in the week, spoken for 2 minutes.","Read the model essays from Days 5 and 9 aloud."]}],"tasks":[{"id":"d13-s1","kind":"speaking","part":1,"title":"Quick-fire Speaking Part 1 (20 questions)","intro":"Answer each question in 2–3 sentences, quickly and naturally. Press “Next question” after each answer.","sets":[{"topic":"Quick-fire","qs":["What’s your full name?","Do you work or study?","What do you like about your studies?","What time do you usually wake up?","Do you prefer mornings or evenings?","What did you do last weekend?","Do you like cooking?","What’s your favourite season?","Do you like living in your town?","How often do you see your friends?","Do you prefer texting or calling?","What kind of films do you enjoy?","Have you ever been to a museum?","Do you like wearing a watch?","What do you do to relax?","Is it easy to find a job in your town?","Do you like to plan things in advance?","What would you like to learn in the future?","Do you enjoy being outdoors?","What makes you happy?"]}],"maxSeconds":900,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d13-l1","kind":"listening","title":"Short dictation (6 sentences)","intro":"You will hear 6 sentences, once each. Write each sentence exactly. Use numbers and symbols where it is natural (for example £950, 17.5%).","preview":10,"itemPause":12,"announce":true,"auto":false,"groups":[{"type":"text","long":true,"qs":[["1",""],["2",""],["3",""],["4",""],["5",""],["6",""]]}],"hasModel":true,"hasScript":true,"autoMarked":false,"scriptItems":6}],"vocab":[],"homework":["Sleep early. Have your passport, pencils and water ready for tomorrow’s mock."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (13, $ielts$[{"after":3,"text":"Finish early. A rested candidate performs better than a tired one."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d13-s1$ielts$, 13, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d13-l1$ielts$, 13, $ielts$listening$ielts$, false, null, $ielts$[{"n":"1","lines":["Wednesday the fourteenth of February."]},{"n":"2","lines":["Accommodation costs nine hundred and fifty pounds."]},{"n":"3","lines":["The conference is in Room 3 B."]},{"n":"4","lines":["Her surname is Nwachukwu. N-W-A-C-H-U-K-W-U."]},{"n":"5","lines":["Seventeen point five per cent."]},{"n":"6","lines":["The questionnaire must be returned by Friday."]}]$ielts$::jsonb, $ielts${"1":"Wednesday 14 February / Wednesday the 14th of February","2":"Accommodation costs £950.","3":"The conference is in Room 3B.","4":"Her surname is Nwachukwu.","5":"17.5%","6":"The questionnaire must be returned by Friday."}$ielts$::jsonb, $ielts$Marked by Claude/tutor: check spelling of accommodation, conference, questionnaire, Wednesday, February and the name.$ielts$, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.lessons (day, title, data) values (14, $ielts$MOCK TEST 2 and Exam Briefing$ielts$, $ielts${"goals":["Sit a second full mock under exam conditions","Measure progress from Mock 1 and EF SET","Prepare for exam day"],"timing":"Full mock 3 hours · Marking 45 min · Briefing 30 min","lesson":[{"h":"Exam conditions"},{"p":"Unseen Cambridge IELTS Academic test for Listening and Reading, under exam conditions as on Day 7."},{"h":"Exam-day briefing"},{"list":["Bring the same passport used for registration. Arrive early.","Listening: use the reading time to underline key words and predict answers.","Reading: do not spend more than 20 minutes on any passage; guess rather than leave blanks.","Writing: plan for 5 minutes; check word counts; leave 3 minutes to check grammar and spelling.","Speaking: smile, speak at a steady pace, and ask the examiner to repeat a question if needed. Don’t memorise answers; examiners notice.","Sleep well the night before. Eat a proper breakfast."]}],"tasks":[{"id":"d14-ls","kind":"sheet","skill":"listening","title":"Mock 2: Listening (Cambridge book)","count":40,"minutes":40,"intro":"Unseen Cambridge IELTS Academic Listening test. Play the audio once without pausing and type your 40 answers here.","hasModel":false,"hasScript":false,"autoMarked":true},{"id":"d14-rs","kind":"sheet","skill":"reading","title":"Mock 2: Academic Reading (Cambridge book)","count":40,"minutes":60,"intro":"Unseen Cambridge IELTS Academic Reading test. 60 minutes. Type your 40 answers here.","hasModel":false,"hasScript":false,"autoMarked":true},{"id":"d14-w1","kind":"writing","task":1,"title":"Mock 2: Writing Task 1 (bar chart)","minutes":20,"minWords":150,"prompt":"The chart below shows the average number of hours per day spent on leisure screen time by different age groups on weekdays and at weekends.","tail":"Summarise the information by selecting and reporting the main features, and make comparisons where relevant. Write at least 150 words.","img":"c_day14_bar.png","chartData":"Bar chart, average daily leisure screen time (hours), weekdays vs weekends, by age group. 10–15: 3.5 / 6.0; 16–24: 5.0 / 7.5; 25–44: 4.0 / 5.5; 45–64: 3.0 / 4.0; 65+: 2.5 / 3.0.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d14-w2","kind":"writing","task":2,"title":"Mock 2: Writing Task 2","minutes":40,"minWords":250,"prompt":"Some people say that the best way to improve public health is to build more sports facilities. Others believe that this would have little effect and that other measures are needed. Discuss both views and give your own opinion.","tail":"Give reasons for your answer and include any relevant examples from your own knowledge or experience. Write at least 250 words.","hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d14-s1","kind":"speaking","part":1,"title":"Mock 2: Speaking Part 1","intro":"Answer in 2–3 sentences. Press “Next question” after each answer.","sets":[{"topic":"Family","qs":["How many people are there in your family?","Who are you closest to?"]},{"topic":"The internet","qs":["How much time do you spend online each day?","What did you last search for online?"]}],"maxSeconds":360,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d14-s2","kind":"speaking","part":2,"title":"Mock 2: Speaking Part 2","intro":"You have 1 minute to make notes, then speak for 1–2 minutes.","cards":[{"topic":"Describe a time when you helped someone.","bullets":["who you helped","what the situation was","how you helped them","and explain how you felt about it."]}],"prep":60,"maxSeconds":120,"hasModel":false,"hasScript":false,"autoMarked":false},{"id":"d14-s3","kind":"speaking","part":3,"title":"Mock 2: Speaking Part 3","intro":"Give developed answers (4–6 sentences).","sets":[{"topic":"Helping others","qs":["Why do some people enjoy helping others?","Should schools teach children to volunteer?","Do people help their neighbours less than in the past?","Should helping the poor be the responsibility of governments or individuals?"]}],"maxSeconds":420,"hasModel":false,"hasScript":false,"autoMarked":false}],"vocab":[["facility","a building or place for a purpose","sports facilities"],["measure (n)","an action taken to achieve something","preventive measures"],["obesity","being very overweight","tackle obesity"],["promote","to encourage","promote healthy habits"],["volunteer","to work without pay to help","volunteer in the community"],["responsibility","a duty","shared responsibility"],["leisure","free time","leisure activities"],["considerably","by a large amount","considerably higher"]],"homework":["Book the IELTS test (or confirm the booking) based on your Mock 2 results."]}$ielts$::jsonb)
  on conflict (day) do update set title = excluded.title, data = excluded.data, updated_at = now();

insert into public.lesson_private (day, notes) values (14, $ielts$[{"after":3,"text":"Task 1 key features: screen time is higher at weekends for every age group; 16–24s have the most (5 and 7.5 hours); time falls steadily with age after 24, to 2.5 and 3 hours for over-65s; the weekend gap is largest for the two youngest groups (2.5 hours each) and smallest for 65+ (0.5 hours). If Mock 2 shows any skill below 6.0, recommend extra practice in that skill before booking the exam."}]$ielts$::jsonb)
  on conflict (day) do update set notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d14-ls$ielts$, 14, $ielts$sheet$ielts$, true, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d14-rs$ielts$, 14, $ielts$sheet$ielts$, true, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d14-w1$ielts$, 14, $ielts$writing$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d14-w2$ielts$, 14, $ielts$writing$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d14-s1$ielts$, 14, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d14-s2$ielts$, 14, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;

insert into public.task_private (task_id, day, kind, auto, key, script, model, notes, plays)
  values ($ielts$d14-s3$ielts$, 14, $ielts$speaking$ielts$, false, null, null, null, null, 1)
  on conflict (task_id) do update set day = excluded.day, kind = excluded.kind, auto = excluded.auto,
    key = coalesce(excluded.key, public.task_private.key), script = excluded.script, model = excluded.model, notes = excluded.notes;


-- ─────────────────────────────── EXISTING ACCOUNTS ────────────────────
-- (If you created the two users before running this file, this links them up.)
insert into public.profiles (id, email, full_name)
select u.id, u.email, split_part(u.email, '@', 1) from auth.users u
on conflict (id) do nothing;

insert into public.day_access (student_id, day)
select p.id, 1 from public.profiles p where p.role = 'student'
on conflict do nothing;

select t.check_item as "Setup check", case when t.ok then '✓ OK' else '⚠ See the setup guide: Troubleshooting' end as "Result"
from (values
  (1, 'Lessons loaded (14 days)', (select count(*) from public.lessons) = 14),
  (2, 'Exercises loaded', (select count(*) from public.task_private) >= 70),
  (3, 'Accounts linked (should be at least 2)', (select count(*) from public.profiles) >= 2),
  (4, 'Tutor account set (run the make-tutor line next)', exists (select 1 from public.profiles where role = 'tutor')),
  (5, 'New accounts linked automatically', exists (select 1 from pg_trigger where tgname = 'ielts_on_auth_user_created')),
  (6, 'Recordings storage', exists (select 1 from storage.buckets where id = 'recordings')),
  (7, 'Live updates', exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'chat_messages'))
) as t(n, check_item, ok)
order by t.n;
