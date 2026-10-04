-- Vihaa Grammar Adventure · Golden Balloon Contest
-- Safe public design: no exact home address is collected.
-- Sensitive entry data is never directly selectable by anon users.

create extension if not exists pgcrypto;
create extension if not exists pg_cron with schema extensions;

create table if not exists public.vihaa_balloon_progress (
  device_token uuid primary key,
  letters text not null default '',
  letter_count smallint not null default 0 check (letter_count between 0 and 5),
  last_claim_date date,
  updated_at timestamptz not null default now()
);

create table if not exists public.vihaa_contest_entries (
  id uuid primary key default gen_random_uuid(),
  device_token uuid not null,
  week_start date not null,
  child_name text not null check (char_length(child_name) between 1 and 30),
  age smallint not null check (age between 4 and 18),
  class_name text not null check (char_length(class_name) between 1 and 20),
  school_name text check (school_name is null or char_length(school_name) <= 80),
  city_district text not null check (char_length(city_district) between 1 and 60),
  guardian_contact text not null check (char_length(guardian_contact) between 3 and 80),
  screenshot_mime text not null check (screenshot_mime in ('image/png','image/jpeg','image/webp')),
  screenshot_bytes bytea not null,
  consent boolean not null check (consent = true),
  created_at timestamptz not null default now(),
  unique(device_token, week_start)
);

create table if not exists public.vihaa_winners (
  id uuid primary key default gen_random_uuid(),
  week_start date not null unique,
  entry_id uuid not null unique references public.vihaa_contest_entries(id) on delete restrict,
  public_name text not null,
  public_class text not null,
  public_city text not null,
  announced_at timestamptz not null default now()
);

alter table public.vihaa_balloon_progress enable row level security;
alter table public.vihaa_contest_entries enable row level security;
alter table public.vihaa_winners enable row level security;

-- Sensitive tables intentionally have no anon SELECT/INSERT/UPDATE policies.
-- Only the SECURITY DEFINER RPCs below can access them.
drop policy if exists "Public can read sanitized winners" on public.vihaa_winners;
create policy "Public can read sanitized winners"
on public.vihaa_winners for select
to anon, authenticated
using (true);

create or replace function public.vihaa_secret_minute(p_device uuid, p_day date)
returns integer
language sql
immutable
set search_path = public
as $$
  -- 08:00–20:59 IST. hashtextextended creates a deterministic but non-obvious
  -- per-device/per-day minute. The exact minute is never returned to clients.
  select 480 + mod(abs(hashtextextended(p_device::text || ':' || p_day::text, 8642026)), 780)::integer;
$$;

create or replace function public.vihaa_balloon_status(p_device uuid)
returns table(active boolean, letter_count smallint, letters text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamp := timezone('Asia/Kolkata', now());
  v_day date := v_now::date;
  v_minute integer := extract(hour from v_now)::integer * 60 + extract(minute from v_now)::integer;
  v_target integer := public.vihaa_secret_minute(p_device, v_day);
  v_count smallint := 0;
  v_letters text := '';
  v_last date;
begin
  select p.letter_count,p.letters,p.last_claim_date
    into v_count,v_letters,v_last
  from public.vihaa_balloon_progress p
  where p.device_token=p_device;

  v_count := coalesce(v_count,0);
  v_letters := coalesce(v_letters,'');

  return query
  select (
      v_count < 5
      and v_last is distinct from v_day
      and v_minute >= v_target
      and v_minute < v_target + 20
    ),
    v_count,
    v_letters;
end;
$$;

create or replace function public.vihaa_claim_golden_letter(p_device uuid)
returns table(success boolean, letter text, letter_count smallint, letters text, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamp := timezone('Asia/Kolkata', now());
  v_day date := v_now::date;
  v_minute integer := extract(hour from v_now)::integer * 60 + extract(minute from v_now)::integer;
  v_target integer := public.vihaa_secret_minute(p_device, v_day);
  v_count smallint := 0;
  v_letters text := '';
  v_last date;
  v_letter text;
begin
  insert into public.vihaa_balloon_progress(device_token)
  values(p_device)
  on conflict (device_token) do nothing;

  select p.letter_count,p.letters,p.last_claim_date
    into v_count,v_letters,v_last
  from public.vihaa_balloon_progress p
  where p.device_token=p_device
  for update;

  if v_count >= 5 then
    return query select false,null::text,v_count,v_letters,'VIHAA already complete';
    return;
  end if;

  if v_last = v_day then
    return query select false,null::text,v_count,v_letters,'Today''s golden letter was already collected';
    return;
  end if;

  if not (v_minute >= v_target and v_minute < v_target + 20) then
    return query select false,null::text,v_count,v_letters,'Golden balloon is not active now';
    return;
  end if;

  v_letter := substring('VIHAA' from v_count + 1 for 1);
  v_count := v_count + 1;
  v_letters := v_letters || v_letter;

  update public.vihaa_balloon_progress
  set letter_count=v_count,letters=v_letters,last_claim_date=v_day,updated_at=now()
  where device_token=p_device;

  return query select true,v_letter,v_count,v_letters,'Golden letter collected';
end;
$$;

create or replace function public.vihaa_submit_entry(
  p_device uuid,
  p_child_name text,
  p_age smallint,
  p_class_name text,
  p_school_name text,
  p_city_district text,
  p_guardian_contact text,
  p_screenshot_mime text,
  p_screenshot_base64 text,
  p_consent boolean
)
returns table(success boolean, entry_id uuid, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count smallint;
  v_week date := date_trunc('week', timezone('Asia/Kolkata',now()))::date;
  v_bytes bytea;
  v_id uuid;
begin
  if p_consent is distinct from true then
    return query select false,null::uuid,'Parent/guardian consent is required';
    return;
  end if;

  select letter_count into v_count
  from public.vihaa_balloon_progress
  where device_token=p_device;

  if coalesce(v_count,0) < 5 then
    return query select false,null::uuid,'Complete VIHAA before submitting';
    return;
  end if;

  if p_screenshot_mime not in ('image/png','image/jpeg','image/webp') then
    return query select false,null::uuid,'Unsupported screenshot format';
    return;
  end if;

  begin
    v_bytes := decode(regexp_replace(p_screenshot_base64,'^data:image/[^;]+;base64,',''),'base64');
  exception when others then
    return query select false,null::uuid,'Invalid screenshot';
    return;
  end;

  if octet_length(v_bytes) > 1572864 then
    return query select false,null::uuid,'Screenshot must be 1.5 MB or smaller after compression';
    return;
  end if;

  begin
    insert into public.vihaa_contest_entries(
      device_token,week_start,child_name,age,class_name,school_name,city_district,
      guardian_contact,screenshot_mime,screenshot_bytes,consent
    ) values (
      p_device,v_week,trim(p_child_name),p_age,trim(p_class_name),nullif(trim(p_school_name),''),
      trim(p_city_district),trim(p_guardian_contact),p_screenshot_mime,v_bytes,true
    )
    returning id into v_id;
  exception when unique_violation then
    return query select false,null::uuid,'One contest entry per week is allowed';
    return;
  end;

  return query select true,v_id,'Entry received securely';
end;
$$;

create or replace function public.vihaa_current_winner()
returns table(public_name text, public_class text, public_city text, announced_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select w.public_name,w.public_class,w.public_city,w.announced_at
  from public.vihaa_winners w
  order by w.announced_at desc
  limit 1;
$$;

create or replace function public.vihaa_pick_weekly_winner()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week date := date_trunc('week', timezone('Asia/Kolkata',now()))::date;
  v_entry public.vihaa_contest_entries%rowtype;
  v_winner uuid;
begin
  if exists(select 1 from public.vihaa_winners where week_start=v_week) then
    select id into v_winner from public.vihaa_winners where week_start=v_week;
    return v_winner;
  end if;

  select e.* into v_entry
  from public.vihaa_contest_entries e
  where e.week_start=v_week
    and not exists(select 1 from public.vihaa_winners w where w.entry_id=e.id)
  order by random()
  limit 1;

  if v_entry.id is null then return null; end if;

  insert into public.vihaa_winners(week_start,entry_id,public_name,public_class,public_city)
  values(v_week,v_entry.id,v_entry.child_name,v_entry.class_name,v_entry.city_district)
  returning id into v_winner;

  return v_winner;
end;
$$;

revoke all on function public.vihaa_secret_minute(uuid,date) from public,anon,authenticated;
revoke all on function public.vihaa_pick_weekly_winner() from public,anon,authenticated;

grant execute on function public.vihaa_balloon_status(uuid) to anon,authenticated;
grant execute on function public.vihaa_claim_golden_letter(uuid) to anon,authenticated;
grant execute on function public.vihaa_submit_entry(uuid,text,smallint,text,text,text,text,text,text,boolean) to anon,authenticated;
grant execute on function public.vihaa_current_winner() to anon,authenticated;

-- Sunday 18:00 IST = 12:30 UTC.
do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname='vihaa-sunday-winner';
exception when others then
  null;
end $$;

select cron.schedule(
  'vihaa-sunday-winner',
  '30 12 * * 0',
  $$select public.vihaa_pick_weekly_winner();$$
);
