-- Inganzo World Culture Library: Supabase database schema
-- Run this entire file in Supabase Dashboard > SQL Editor.

create extension if not exists pgcrypto;

create or replace function public.inganzo_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;

create table if not exists public.organizers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  organization_name text not null check (char_length(organization_name) between 2 and 120),
  contact_email text,
  country text,
  created_at timestamptz not null default now(),
  unique(user_id, organization_name)
);

create table if not exists public.event_proposals (
  id uuid primary key default gen_random_uuid(),
  organizer_name text not null check (char_length(organizer_name) between 2 and 120),
  contact_email text not null check (char_length(contact_email) <= 254),
  title text not null check (char_length(title) between 3 and 140),
  event_type text not null check (event_type in (
    'Speech or public talk', 'Song or live music', 'Dance performance',
    'Storytelling or poetry', 'Cultural exhibition or demonstration', 'Other cultural show'
  )),
  preferred_date date,
  description text not null check (char_length(description) between 10 and 2000),
  status text not null default 'pending' check (status in ('pending','under_review','approved','rejected','withdrawn')),
  submitted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  admin_notes text
);

create table if not exists public.performers (
  id uuid primary key default gen_random_uuid(),
  display_name text not null check (char_length(display_name) between 2 and 120),
  bio text,
  country text,
  culture text,
  is_public boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.cultural_events (
  id uuid primary key default gen_random_uuid(),
  proposal_id uuid references public.event_proposals(id) on delete set null,
  organizer_id uuid references public.organizers(id) on delete set null,
  title text not null check (char_length(title) between 3 and 140),
  event_type text not null,
  description text not null default '',
  starts_at timestamptz,
  ends_at timestamptz,
  venue text,
  country text,
  status text not null default 'draft' check (status in ('draft','published','cancelled','completed')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint event_time_order check (ends_at is null or starts_at is null or ends_at > starts_at)
);

create table if not exists public.event_performers (
  event_id uuid not null references public.cultural_events(id) on delete cascade,
  performer_id uuid not null references public.performers(id) on delete cascade,
  performance_role text,
  sort_order integer not null default 0,
  primary key (event_id, performer_id)
);

create index if not exists event_proposals_status_created_idx on public.event_proposals(status, created_at desc);
create index if not exists cultural_events_status_start_idx on public.cultural_events(status, starts_at);
create index if not exists performers_public_idx on public.performers(is_public);

alter table public.organizers enable row level security;
alter table public.event_proposals enable row level security;
alter table public.performers enable row level security;
alter table public.cultural_events enable row level security;
alter table public.event_performers enable row level security;

-- Visitors may submit proposals. They cannot read, change, approve, or delete proposals.
drop policy if exists "public_submit_event_proposals" on public.event_proposals;
create policy "public_submit_event_proposals" on public.event_proposals
  for insert to anon, authenticated
  with check (status = 'pending' and (submitted_by is null or submitted_by = auth.uid()));

drop policy if exists "admins_manage_event_proposals" on public.event_proposals;
create policy "admins_manage_event_proposals" on public.event_proposals
  for all to authenticated
  using (public.inganzo_is_admin())
  with check (public.inganzo_is_admin());

-- Published events and explicitly public performer profiles are visible to everyone.
drop policy if exists "public_read_published_events" on public.cultural_events;
create policy "public_read_published_events" on public.cultural_events
  for select to anon, authenticated using (status = 'published');
drop policy if exists "admins_manage_cultural_events" on public.cultural_events;
create policy "admins_manage_cultural_events" on public.cultural_events
  for all to authenticated using (public.inganzo_is_admin()) with check (public.inganzo_is_admin());

drop policy if exists "public_read_public_performers" on public.performers;
create policy "public_read_public_performers" on public.performers
  for select to anon, authenticated using (is_public = true);
drop policy if exists "admins_manage_performers" on public.performers;
create policy "admins_manage_performers" on public.performers
  for all to authenticated using (public.inganzo_is_admin()) with check (public.inganzo_is_admin());

drop policy if exists "public_read_event_performers_for_published_events" on public.event_performers;
create policy "public_read_event_performers_for_published_events" on public.event_performers
  for select to anon, authenticated using (
    exists (select 1 from public.cultural_events e where e.id = event_id and e.status = 'published')
  );
drop policy if exists "admins_manage_event_performers" on public.event_performers;
create policy "admins_manage_event_performers" on public.event_performers
  for all to authenticated using (public.inganzo_is_admin()) with check (public.inganzo_is_admin());

-- Organizers can see and update only their own organization record; admins can manage all.
drop policy if exists "organizers_read_own" on public.organizers;
create policy "organizers_read_own" on public.organizers
  for select to authenticated using (user_id = auth.uid() or public.inganzo_is_admin());
drop policy if exists "organizers_insert_own" on public.organizers;
create policy "organizers_insert_own" on public.organizers
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "organizers_update_own" on public.organizers;
create policy "organizers_update_own" on public.organizers
  for update to authenticated using (user_id = auth.uid() or public.inganzo_is_admin())
  with check (user_id = auth.uid() or public.inganzo_is_admin());
drop policy if exists "admins_delete_organizers" on public.organizers;
create policy "admins_delete_organizers" on public.organizers
  for delete to authenticated using (public.inganzo_is_admin());

-- Minimum required API privileges; row-level security above remains authoritative.
grant usage on schema public to anon, authenticated;
grant insert on public.event_proposals to anon, authenticated;
grant select, insert, update, delete on public.organizers to authenticated;
grant select, insert, update, delete on public.event_proposals to authenticated;
grant select, insert, update, delete on public.performers to authenticated;
grant select, insert, update, delete on public.cultural_events to authenticated;
grant select, insert, update, delete on public.event_performers to authenticated;
grant select on public.cultural_events, public.performers, public.event_performers to anon;

-- IMPORTANT: Set an administrator's app_metadata.role to "admin" using Supabase Auth
-- (Dashboard > Authentication > Users > select user > Edit app metadata).
-- Never put the Supabase service_role key in website HTML or browser JavaScript.
