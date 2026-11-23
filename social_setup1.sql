-- Vulcan Health: Social (profiles, friends, feed, challenges)
-- Run once in Supabase -> SQL Editor -> New query -> Run. Safe to run more than once.
-- Everything here is private by default: people only see their own rows and their accepted friends' posts.

-- ============ 1) Profiles ============
create table if not exists public.profiles (
  user_id      uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  username     text not null,
  display_name text not null default '',
  visibility   text not null default 'friends' check (visibility in ('friends', 'private')),  -- private = nobody can find you
  showcase     text[] not null default '{}',                                                   -- up to 3 badge ids
  stats        jsonb not null default '{}'::jsonb,
  updated_at   timestamptz not null default now(),
  constraint profiles_username_fmt check (username ~ '^[a-z0-9_]{3,20}$'),
  constraint profiles_showcase_len check (coalesce(array_length(showcase, 1), 0) <= 3),
  constraint profiles_name_len check (char_length(display_name) <= 40)
);
create unique index if not exists profiles_username_key on public.profiles (username);
alter table public.profiles add column if not exists bio text not null default '';
alter table public.profiles add column if not exists avatar_path text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_bio_len') then
    alter table public.profiles add constraint profiles_bio_len check (char_length(bio) <= 160);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_avatar_owner') then
    alter table public.profiles add constraint profiles_avatar_owner check (avatar_path is null or avatar_path like user_id::text || '/%');
  end if;
end $$;

-- ============ 2) Friends and blocks ============
create table if not exists public.friendships (
  id         uuid primary key default gen_random_uuid(),
  requester  uuid not null references auth.users(id) on delete cascade,
  addressee  uuid not null references auth.users(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  constraint friendships_not_self check (requester <> addressee)
);
create unique index if not exists friendships_pair_key on public.friendships (least(requester, addressee), greatest(requester, addressee));
create index if not exists friendships_addressee_idx on public.friendships (addressee);

create table if not exists public.blocks (
  blocker    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  blocked    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  constraint blocks_not_self check (blocker <> blocked)
);

-- ============ 3) Posts, reactions, comments, reports ============
create table if not exists public.posts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  caption    text not null default '' check (char_length(caption) <= 280),
  workout    jsonb,
  photo_path text,
  created_at timestamptz not null default now(),
  constraint posts_has_content check (workout is not null or photo_path is not null or caption <> ''),
  constraint posts_photo_owner check (photo_path is null or photo_path like user_id::text || '/%')
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'posts_workout_size') then
    alter table public.posts add constraint posts_workout_size check (workout is null or pg_column_size(workout) <= 8000);
  end if;
end $$;
create index if not exists posts_user_idx on public.posts (user_id, created_at desc);
create index if not exists posts_created_idx on public.posts (created_at desc);

create table if not exists public.reactions (
  post_id    uuid not null references public.posts(id) on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  emoji      text not null check (emoji in ('🔥', '💪', '👏', '❤️')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.posts(id) on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body       text not null check (char_length(btrim(body)) between 1 and 200),
  created_at timestamptz not null default now()
);
create index if not exists comments_post_idx on public.comments (post_id, created_at);

create table if not exists public.reports (
  id         uuid primary key default gen_random_uuid(),
  reporter   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('post', 'comment', 'user')),
  target     text not null check (char_length(target) <= 64),
  reason     text not null default '' check (char_length(reason) <= 300),
  created_at timestamptz not null default now()
);

-- ============ 4) Challenges ============
create table if not exists public.challenges (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title      text not null check (char_length(btrim(title)) between 1 and 40),
  metric     text not null check (metric in ('steps', 'workouts', 'minutes', 'calories')),
  start_date date not null,
  end_date   date not null,
  created_at timestamptz not null default now(),
  constraint challenges_window check (end_date >= start_date and end_date - start_date <= 60)
);
create table if not exists public.challenge_members (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  status       text not null default 'invited' check (status in ('invited', 'joined')),
  created_at   timestamptz not null default now(),
  primary key (challenge_id, user_id)
);
create index if not exists challenge_members_user_idx on public.challenge_members (user_id);
create table if not exists public.challenge_scores (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  day          date not null,
  value        integer not null check (value between 0 and 1000000),
  primary key (challenge_id, user_id, day)
);

-- ============ 5) Helper functions (used by the access rules) ============
create or replace function public.is_friend(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.friendships f
    where f.status = 'accepted' and ((f.requester = a and f.addressee = b) or (f.requester = b and f.addressee = a)));
$$;
create or replace function public.is_blocked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.blocks k where (k.blocker = a and k.blocked = b) or (k.blocker = b and k.blocked = a));
$$;
create or replace function public.can_see_user(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (target = auth.uid() or (public.is_friend(auth.uid(), target) and not public.is_blocked(auth.uid(), target)));
$$;
create or replace function public.can_see_post(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.posts p where p.id = pid and public.can_see_user(p.user_id));
$$;
create or replace function public.in_challenge(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.challenge_members m where m.challenge_id = cid and m.user_id = auth.uid());
$$;
create or replace function public.can_score(cid uuid, d date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.challenge_members m join public.challenges c on c.id = m.challenge_id
    where m.challenge_id = cid and m.user_id = auth.uid() and m.status = 'joined' and d between c.start_date and c.end_date);
$$;
create or replace function public.can_see_photo(name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare owner_txt text := split_part(name, '/', 1);
begin
  if auth.uid() is null or owner_txt !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return public.can_see_user(owner_txt::uuid);
end $$;

-- ============ 6) Simple anti-spam limits ============
create or replace function public.limit_rate() returns trigger language plpgsql security definer set search_path = public as $$
declare n int; cap int := tg_argv[0]::int; who uuid;
begin
  if tg_table_name = 'posts' then select count(*) into n from public.posts where user_id = new.user_id and created_at > now() - interval '1 day'; who := new.user_id;
  elsif tg_table_name = 'comments' then select count(*) into n from public.comments where user_id = new.user_id and created_at > now() - interval '1 day'; who := new.user_id;
  elsif tg_table_name = 'reports' then select count(*) into n from public.reports where reporter = new.reporter and created_at > now() - interval '1 day'; who := new.reporter;
  end if;
  if n >= cap then raise exception 'Daily limit reached. Please try again tomorrow.'; end if;
  return new;
end $$;
drop trigger if exists posts_rate on public.posts;
create trigger posts_rate before insert on public.posts for each row execute function public.limit_rate(30);
drop trigger if exists comments_rate on public.comments;
create trigger comments_rate before insert on public.comments for each row execute function public.limit_rate(150);
drop trigger if exists reports_rate on public.reports;
create trigger reports_rate before insert on public.reports for each row execute function public.limit_rate(30);

-- ============ 7) Access rules (row level security) ============
alter table public.profiles          enable row level security;
alter table public.friendships       enable row level security;
alter table public.blocks            enable row level security;
alter table public.posts             enable row level security;
alter table public.reactions         enable row level security;
alter table public.comments          enable row level security;
alter table public.reports           enable row level security;
alter table public.challenges        enable row level security;
alter table public.challenge_members enable row level security;
alter table public.challenge_scores  enable row level security;

drop policy if exists "profiles select" on public.profiles;
drop policy if exists "profiles insert own" on public.profiles;
drop policy if exists "profiles update own" on public.profiles;
drop policy if exists "profiles delete own" on public.profiles;
create policy "profiles select" on public.profiles for select using (public.can_see_user(user_id));
create policy "profiles insert own" on public.profiles for insert with check (user_id = auth.uid());
create policy "profiles update own" on public.profiles for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "profiles delete own" on public.profiles for delete using (user_id = auth.uid());

drop policy if exists "friendships select" on public.friendships;
drop policy if exists "friendships accept" on public.friendships;
drop policy if exists "friendships delete" on public.friendships;
create policy "friendships select" on public.friendships for select using (auth.uid() in (requester, addressee));
create policy "friendships accept" on public.friendships for update using (addressee = auth.uid()) with check (addressee = auth.uid() and status = 'accepted');
create policy "friendships delete" on public.friendships for delete using (auth.uid() in (requester, addressee));

drop policy if exists "blocks select own" on public.blocks;
drop policy if exists "blocks delete own" on public.blocks;
create policy "blocks select own" on public.blocks for select using (blocker = auth.uid());
create policy "blocks delete own" on public.blocks for delete using (blocker = auth.uid());

drop policy if exists "posts select" on public.posts;
drop policy if exists "posts insert own" on public.posts;
drop policy if exists "posts delete own" on public.posts;
create policy "posts select" on public.posts for select using (public.can_see_user(user_id));
create policy "posts insert own" on public.posts for insert with check (user_id = auth.uid());
create policy "posts delete own" on public.posts for delete using (user_id = auth.uid());

drop policy if exists "reactions select" on public.reactions;
drop policy if exists "reactions insert own" on public.reactions;
drop policy if exists "reactions update own" on public.reactions;
drop policy if exists "reactions delete own" on public.reactions;
create policy "reactions select" on public.reactions for select using (public.can_see_post(post_id));
create policy "reactions insert own" on public.reactions for insert with check (user_id = auth.uid() and public.can_see_post(post_id));
create policy "reactions update own" on public.reactions for update using (user_id = auth.uid()) with check (user_id = auth.uid() and public.can_see_post(post_id));
create policy "reactions delete own" on public.reactions for delete using (user_id = auth.uid());

drop policy if exists "comments select" on public.comments;
drop policy if exists "comments insert own" on public.comments;
drop policy if exists "comments delete" on public.comments;
create policy "comments select" on public.comments for select using (public.can_see_post(post_id) and not public.is_blocked(auth.uid(), user_id));
create policy "comments insert own" on public.comments for insert with check (user_id = auth.uid() and public.can_see_post(post_id));
create policy "comments delete" on public.comments for delete using (user_id = auth.uid() or exists (select 1 from public.posts p where p.id = post_id and p.user_id = auth.uid()));

drop policy if exists "reports insert own" on public.reports;
create policy "reports insert own" on public.reports for insert with check (reporter = auth.uid());   -- nobody can read reports from the app; read them in the Supabase dashboard

drop policy if exists "challenges select" on public.challenges;
drop policy if exists "challenges delete owner" on public.challenges;
create policy "challenges select" on public.challenges for select using (owner = auth.uid() or public.in_challenge(id));
create policy "challenges delete owner" on public.challenges for delete using (owner = auth.uid());

drop policy if exists "members select" on public.challenge_members;
drop policy if exists "members join" on public.challenge_members;
drop policy if exists "members leave" on public.challenge_members;
create policy "members select" on public.challenge_members for select using (public.in_challenge(challenge_id));
create policy "members join" on public.challenge_members for update using (user_id = auth.uid()) with check (user_id = auth.uid() and status = 'joined');
create policy "members leave" on public.challenge_members for delete using (user_id = auth.uid() or exists (select 1 from public.challenges c where c.id = challenge_id and c.owner = auth.uid()));

drop policy if exists "scores select" on public.challenge_scores;
drop policy if exists "scores insert own" on public.challenge_scores;
drop policy if exists "scores update own" on public.challenge_scores;
drop policy if exists "scores delete own" on public.challenge_scores;
create policy "scores select" on public.challenge_scores for select using (public.in_challenge(challenge_id));
create policy "scores insert own" on public.challenge_scores for insert with check (user_id = auth.uid() and public.can_score(challenge_id, day));
create policy "scores update own" on public.challenge_scores for update using (user_id = auth.uid()) with check (user_id = auth.uid() and public.can_score(challenge_id, day));
create policy "scores delete own" on public.challenge_scores for delete using (user_id = auth.uid());

-- ============ 8) Functions the app calls ============
-- find someone by their exact username (never lists people)
drop function if exists public.find_user(text);
create or replace function public.find_user(uname text)
returns table (user_id uuid, username text, display_name text, showcase text[], avatar_path text)
language sql stable security definer set search_path = public as $$
  select p.user_id, p.username, p.display_name, p.showcase, p.avatar_path from public.profiles p
  where auth.uid() is not null and p.username = lower(btrim(uname)) and p.user_id <> auth.uid()
    and p.visibility <> 'private' and not public.is_blocked(auth.uid(), p.user_id);
$$;

create or replace function public.send_friend_request(target uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); existing public.friendships; pending int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if target is null or target = me then raise exception 'Invalid user'; end if;
  if not exists (select 1 from public.profiles where user_id = me) then raise exception 'Create your profile first'; end if;
  if public.is_blocked(me, target) or not exists (select 1 from public.profiles where user_id = target and visibility <> 'private') then raise exception 'That user can’t be found'; end if;
  select * into existing from public.friendships f where (f.requester = me and f.addressee = target) or (f.requester = target and f.addressee = me);
  if found then
    if existing.status = 'accepted' then return 'friends'; end if;
    if existing.addressee = me then update public.friendships set status = 'accepted' where id = existing.id; return 'friends'; end if;
    return 'pending';
  end if;
  select count(*) into pending from public.friendships where requester = me and status = 'pending';
  if pending >= 40 then raise exception 'Too many pending requests. Wait for some to be answered.'; end if;
  insert into public.friendships (requester, addressee) values (me, target);
  return 'pending';
end $$;

drop function if exists public.my_friend_list();
create or replace function public.my_friend_list()
returns table (friendship_id uuid, user_id uuid, username text, display_name text, showcase text[], stats jsonb, status text, direction text, created_at timestamptz, bio text, avatar_path text)
language sql stable security definer set search_path = public as $$
  select f.id, p.user_id, p.username, p.display_name, p.showcase, p.stats, f.status,
         case when f.requester = auth.uid() then 'out' else 'in' end, f.created_at, p.bio, p.avatar_path
  from public.friendships f
  join public.profiles p on p.user_id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where auth.uid() in (f.requester, f.addressee) and not public.is_blocked(auth.uid(), p.user_id)
  order by f.created_at desc;
$$;

create or replace function public.block_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or target is null or target = auth.uid() then raise exception 'Invalid user'; end if;
  insert into public.blocks (blocker, blocked) values (auth.uid(), target) on conflict do nothing;
  delete from public.friendships where (requester = auth.uid() and addressee = target) or (requester = target and addressee = auth.uid());
  delete from public.challenge_members m using public.challenges c where m.challenge_id = c.id and ((c.owner = auth.uid() and m.user_id = target) or (c.owner = target and m.user_id = auth.uid()));
end $$;

create or replace function public.my_blocks()
returns table (user_id uuid, username text, display_name text)
language sql stable security definer set search_path = public as $$
  select k.blocked, coalesce(p.username, 'unknown'), coalesce(p.display_name, '')
  from public.blocks k left join public.profiles p on p.user_id = k.blocked where k.blocker = auth.uid() order by k.created_at desc;
$$;

drop function if exists public.feed_page(int, timestamptz);
create or replace function public.feed_page(p_limit int default 20, p_before timestamptz default null)
returns table (id uuid, user_id uuid, username text, display_name text, caption text, workout jsonb, photo_path text, created_at timestamptz, react jsonb, mine text, comment_count bigint, avatar_path text)
language sql stable security definer set search_path = public as $$
  select p.id, p.user_id, pr.username, pr.display_name, p.caption, p.workout, p.photo_path, p.created_at,
    coalesce((select jsonb_object_agg(e, n) from (select r.emoji as e, count(*) as n from public.reactions r where r.post_id = p.id group by r.emoji) x), '{}'::jsonb),
    (select r.emoji from public.reactions r where r.post_id = p.id and r.user_id = auth.uid()),
    (select count(*) from public.comments c where c.post_id = p.id and not public.is_blocked(auth.uid(), c.user_id)), pr.avatar_path
  from public.posts p join public.profiles pr on pr.user_id = p.user_id
  where public.can_see_user(p.user_id) and (p_before is null or p.created_at < p_before)
  order by p.created_at desc limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

create or replace function public.profile_posts(target uuid, p_limit int default 20, p_before timestamptz default null)
returns table (id uuid, user_id uuid, username text, display_name text, caption text, workout jsonb, photo_path text, created_at timestamptz, react jsonb, mine text, comment_count bigint, avatar_path text)
language sql stable security definer set search_path = public as $$
  select p.id, p.user_id, pr.username, pr.display_name, p.caption, p.workout, p.photo_path, p.created_at,
    coalesce((select jsonb_object_agg(e, n) from (select r.emoji as e, count(*) as n from public.reactions r where r.post_id = p.id group by r.emoji) x), '{}'::jsonb),
    (select r.emoji from public.reactions r where r.post_id = p.id and r.user_id = auth.uid()),
    (select count(*) from public.comments c where c.post_id = p.id and not public.is_blocked(auth.uid(), c.user_id)), pr.avatar_path
  from public.posts p join public.profiles pr on pr.user_id = p.user_id
  where p.user_id = target and public.can_see_user(p.user_id) and (p_before is null or p.created_at < p_before)
  order by p.created_at desc limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

create or replace function public.post_comments(pid uuid)
returns table (id uuid, user_id uuid, username text, display_name text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.user_id, coalesce(pr.username, 'user'), coalesce(pr.display_name, ''), c.body, c.created_at
  from public.comments c left join public.profiles pr on pr.user_id = c.user_id
  where c.post_id = pid and public.can_see_post(pid) and not public.is_blocked(auth.uid(), c.user_id)
  order by c.created_at asc limit 200;
$$;

create or replace function public.create_challenge(p_title text, p_metric text, p_start date, p_end date, p_invite uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cid uuid; u uuid; made int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select count(*) into made from public.challenges where owner = me and created_at > now() - interval '1 day';
  if made >= 10 then raise exception 'Daily limit reached. Please try again tomorrow.'; end if;
  insert into public.challenges (owner, title, metric, start_date, end_date) values (me, btrim(p_title), p_metric, p_start, p_end) returning id into cid;
  insert into public.challenge_members (challenge_id, user_id, status) values (cid, me, 'joined');
  foreach u in array coalesce(p_invite, '{}') loop
    if u <> me and public.is_friend(me, u) and not public.is_blocked(me, u) then
      insert into public.challenge_members (challenge_id, user_id, status) values (cid, u, 'invited') on conflict do nothing;
    end if;
  end loop;
  return cid;
end $$;

create or replace function public.invite_to_challenge(cid uuid, target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.challenges where id = cid and owner = auth.uid()) then raise exception 'Only the organizer can invite'; end if;
  if not (public.is_friend(auth.uid(), target) and not public.is_blocked(auth.uid(), target)) then raise exception 'You can only invite friends'; end if;
  insert into public.challenge_members (challenge_id, user_id, status) values (cid, target, 'invited') on conflict do nothing;
end $$;

create or replace function public.challenge_board(cid uuid)
returns table (user_id uuid, username text, display_name text, status text, total bigint)
language sql stable security definer set search_path = public as $$
  select m.user_id, coalesce(p.username, 'user'), coalesce(p.display_name, ''), m.status,
         coalesce((select sum(s.value) from public.challenge_scores s where s.challenge_id = cid and s.user_id = m.user_id), 0)
  from public.challenge_members m left join public.profiles p on p.user_id = m.user_id
  where m.challenge_id = cid and public.in_challenge(cid) and not public.is_blocked(auth.uid(), m.user_id)
  order by 5 desc, 2;
$$;

-- remove everything the user has shared on Social (their login and workout data stay)
create or replace function public.delete_my_social() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not signed in'; end if;
  delete from public.posts where user_id = me;                       -- reactions and comments on them go too
  delete from public.comments where user_id = me;
  delete from public.reactions where user_id = me;
  delete from public.challenge_scores where user_id = me;
  delete from public.challenge_members where user_id = me;
  delete from public.challenges where owner = me;
  delete from public.friendships where requester = me or addressee = me;
  delete from public.blocks where blocker = me;
  delete from public.profiles where user_id = me;
end $$;

-- who can run what
revoke all on function public.find_user(text), public.send_friend_request(uuid), public.my_friend_list(), public.block_user(uuid), public.my_blocks(),
  public.feed_page(int, timestamptz), public.profile_posts(uuid, int, timestamptz), public.post_comments(uuid), public.create_challenge(text, text, date, date, uuid[]),
  public.invite_to_challenge(uuid, uuid), public.challenge_board(uuid), public.delete_my_social() from public, anon;
grant execute on function public.find_user(text), public.send_friend_request(uuid), public.my_friend_list(), public.block_user(uuid), public.my_blocks(),
  public.feed_page(int, timestamptz), public.profile_posts(uuid, int, timestamptz), public.post_comments(uuid), public.create_challenge(text, text, date, date, uuid[]),
  public.invite_to_challenge(uuid, uuid), public.challenge_board(uuid), public.delete_my_social() to authenticated;
-- the helper functions are only for the access rules
revoke all on function public.is_friend(uuid, uuid), public.is_blocked(uuid, uuid), public.can_see_user(uuid), public.can_see_post(uuid),
  public.in_challenge(uuid), public.can_score(uuid, date), public.can_see_photo(text) from public, anon;
grant execute on function public.is_friend(uuid, uuid), public.is_blocked(uuid, uuid), public.can_see_user(uuid), public.can_see_post(uuid),
  public.in_challenge(uuid), public.can_score(uuid, date), public.can_see_photo(text) to authenticated;

grant select, insert, update, delete on public.profiles to authenticated;
grant select, update, delete on public.friendships to authenticated;
grant select, delete on public.blocks to authenticated;
grant select, insert, delete on public.posts to authenticated;
grant select, insert, update, delete on public.reactions to authenticated;
grant select, insert, delete on public.comments to authenticated;
grant insert on public.reports to authenticated;
grant select, delete on public.challenges to authenticated;
grant select, update, delete on public.challenge_members to authenticated;
grant select, insert, update, delete on public.challenge_scores to authenticated;

-- ============ 9) Photo storage (private; only you and your friends can see a photo) ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('post-photos', 'post-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "post photos read" on storage.objects;
drop policy if exists "post photos upload own" on storage.objects;
drop policy if exists "post photos delete own" on storage.objects;
create policy "post photos read" on storage.objects for select to authenticated using (bucket_id = 'post-photos' and public.can_see_photo(name));
create policy "post photos upload own" on storage.objects for insert to authenticated with check (bucket_id = 'post-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "post photos delete own" on storage.objects for delete to authenticated using (bucket_id = 'post-photos' and (storage.foldername(name))[1] = auth.uid()::text);
