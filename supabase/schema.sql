-- ============================================================
--  THE RETARDMAXXING BIBLE — Supabase schema
--  Paste this whole file into: Supabase dashboard → SQL Editor → New query → Run.
--  Safe to re-run (uses IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS).
-- ============================================================

-- ---------- PROFILES ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  handle      text unique not null,
  created_at  timestamptz not null default now()
);

-- ---------- POSTS ----------
create table if not exists public.posts (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 500),
  created_at  timestamptz not null default now()
);
create index if not exists posts_created_idx on public.posts (created_at desc);

-- ---------- LIKES ----------
create table if not exists public.likes (
  post_id     bigint not null references public.posts(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- ---------- AUTO-CREATE A PROFILE ON SIGNUP ----------
-- Every new user gets a default handle like  retard_a1b2c3  (they can rename later).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, handle)
  values (new.id, 'retard_' || substr(replace(new.id::text, '-', ''), 1, 6))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- FEED VIEW (post + author handle + like count) ----------
-- security_invoker = the caller's RLS applies (posts are publicly readable below).
create or replace view public.feed
with (security_invoker = true) as
select
  p.id,
  p.body,
  p.created_at,
  pr.handle,
  coalesce(l.cnt, 0) as like_count
from public.posts p
left join public.profiles pr on pr.id = p.user_id
left join (
  select post_id, count(*)::int as cnt
  from public.likes group by post_id
) l on l.post_id = p.id;

-- ============================================================
--  ROW LEVEL SECURITY
-- ============================================================
alter table public.profiles enable row level security;
alter table public.posts    enable row level security;
alter table public.likes    enable row level security;

-- PROFILES: anyone can read; you can only create/edit your own.
drop policy if exists profiles_read   on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy profiles_read   on public.profiles for select using (true);
create policy profiles_insert on public.profiles for insert with check (auth.uid() = id);
create policy profiles_update on public.profiles for update using (auth.uid() = id);

-- POSTS: anyone can read; only signed-in users can post as themselves; delete your own.
drop policy if exists posts_read   on public.posts;
drop policy if exists posts_insert on public.posts;
drop policy if exists posts_delete on public.posts;
create policy posts_read   on public.posts for select using (true);
create policy posts_insert on public.posts for insert with check (auth.uid() = user_id);
create policy posts_delete on public.posts for delete using (auth.uid() = user_id);

-- LIKES: anyone can read counts; you manage only your own likes.
drop policy if exists likes_read   on public.likes;
drop policy if exists likes_insert on public.likes;
drop policy if exists likes_delete on public.likes;
create policy likes_read   on public.likes for select using (true);
create policy likes_insert on public.likes for insert with check (auth.uid() = user_id);
create policy likes_delete on public.likes for delete using (auth.uid() = user_id);

-- ============================================================
--  REALTIME — make the bulletin board live for everyone
--  (new posts / likes broadcast instantly to every open browser)
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname='supabase_realtime' and schemaname='public' and tablename='posts') then
    alter publication supabase_realtime add table public.posts;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname='supabase_realtime' and schemaname='public' and tablename='likes') then
    alter publication supabase_realtime add table public.likes;
  end if;
end $$;

-- ============================================================
--  THE FORUM — threaded discussion board (topics -> threads -> replies)
-- ============================================================
create table if not exists public.threads (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  category    text not null default 'General',
  title       text not null check (char_length(title) between 1 and 120),
  body        text not null check (char_length(body) between 1 and 4000),
  created_at  timestamptz not null default now(),
  bumped_at   timestamptz not null default now()
);
create index if not exists threads_bumped_idx on public.threads (bumped_at desc);

create table if not exists public.replies (
  id          bigint generated always as identity primary key,
  thread_id   bigint not null references public.threads(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 4000),
  created_at  timestamptz not null default now()
);
create index if not exists replies_thread_idx on public.replies (thread_id, created_at);

-- bump a thread to the top whenever it gets a reply
create or replace function public.bump_thread()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.threads set bumped_at = now() where id = new.thread_id;
  return new;
end; $$;
drop trigger if exists on_reply_bump on public.replies;
create trigger on_reply_bump after insert on public.replies
  for each row execute function public.bump_thread();

-- thread list with author handle + reply count
create or replace view public.thread_list
with (security_invoker = true) as
select t.id, t.category, t.title, t.created_at, t.bumped_at,
       pr.handle as author,
       coalesce(r.cnt, 0) as reply_count
from public.threads t
left join public.profiles pr on pr.id = t.user_id
left join (select thread_id, count(*)::int as cnt from public.replies group by thread_id) r
       on r.thread_id = t.id;

-- replies with author handle
create or replace view public.reply_list
with (security_invoker = true) as
select r.id, r.thread_id, r.body, r.created_at, pr.handle as author
from public.replies r
left join public.profiles pr on pr.id = r.user_id;

alter table public.threads enable row level security;
alter table public.replies enable row level security;

drop policy if exists threads_read   on public.threads;
drop policy if exists threads_insert on public.threads;
drop policy if exists threads_delete on public.threads;
create policy threads_read   on public.threads for select using (true);
create policy threads_insert on public.threads for insert with check (auth.uid() = user_id);
create policy threads_delete on public.threads for delete using (auth.uid() = user_id);

drop policy if exists replies_read   on public.replies;
drop policy if exists replies_insert on public.replies;
drop policy if exists replies_delete on public.replies;
create policy replies_read   on public.replies for select using (true);
create policy replies_insert on public.replies for insert with check (auth.uid() = user_id);
create policy replies_delete on public.replies for delete using (auth.uid() = user_id);

-- make the forum live too
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname='supabase_realtime' and schemaname='public' and tablename='threads') then
    alter publication supabase_realtime add table public.threads;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname='supabase_realtime' and schemaname='public' and tablename='replies') then
    alter publication supabase_realtime add table public.replies;
  end if;
end $$;

-- ============================================================
--  HANDLE RULES — enforce clean, unique tag names people pick
-- ============================================================
-- lowercase, 3-20 chars, letters/numbers/underscore only
alter table public.profiles drop constraint if exists handle_format;
alter table public.profiles add constraint handle_format
  check (handle ~ '^[a-z0-9_]{3,20}$');

-- Done. The Congregation and the Forum are open.
