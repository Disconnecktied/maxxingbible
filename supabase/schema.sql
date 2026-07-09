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

-- Done. The Congregation is open.
