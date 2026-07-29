-- =============================================================
-- Pinkas — Phase 1 schema
-- Target: Postgres 15+ (Supabase). Becomes migration 0001_init.sql
-- =============================================================

create extension if not exists pgcrypto;

-- ---------- enums ----------
create type bride_status     as enum ('lead','active','completed','paused','cancelled');
create type course_status    as enum ('draft','active','completed','cancelled');
create type session_status   as enum ('planned','done','cancelled','rescheduled');
create type payment_method   as enum ('cash','bit','paybox','transfer','check','other');
create type payer_type       as enum ('bride','family','religious_council','other');
create type message_channel  as enum ('whatsapp','sms','portal');
create type message_status   as enum ('composed','failed');
create type material_kind    as enum ('file','link');
create type calendar_system  as enum ('gregorian','hebrew');
create type risk_level       as enum ('none','info','medium','high','critical');

-- ---------- shared trigger ----------
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ---------- instructor (the tenant) ----------
create table instructor (
  id                  uuid primary key,          -- = auth.users.id = tenant_id
  full_name           text not null,
  phone               text not null,
  email               text,
  org_affiliation     text,
  default_price       numeric(10,2) check (default_price >= 0),
  currency            char(3) not null default 'ILS',
  timezone            text not null default 'Asia/Jerusalem',
  default_buffer_days smallint not null default 14
                        check (default_buffer_days between 0 and 120),
  locale              text not null default 'he-IL',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz
);
create trigger instructor_touch before update on instructor
  for each row execute function set_updated_at();

-- ---------- curriculum (template) ----------
create table curriculum (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references instructor(id) on delete cascade,
  name                  text not null,
  description           text,
  default_session_count smallint not null default 8
                          check (default_session_count between 1 and 40),
  default_price         numeric(10,2) check (default_price >= 0),
  is_archived           boolean not null default false,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz
);
create index curriculum_tenant_idx on curriculum (tenant_id) where deleted_at is null;
create trigger curriculum_touch before update on curriculum
  for each row execute function set_updated_at();

create table curriculum_topic (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references instructor(id) on delete cascade,
  curriculum_id     uuid not null references curriculum(id) on delete cascade,
  order_index       integer not null,
  title             text not null,
  description       text,
  estimated_minutes smallint check (estimated_minutes > 0),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  -- deferrable: drag-to-reorder (story A2) rewrites the whole sequence in one statement
  constraint curriculum_topic_order_uniq unique (curriculum_id, order_index)
    deferrable initially deferred
);
create index curriculum_topic_curriculum_idx
  on curriculum_topic (curriculum_id, order_index) where deleted_at is null;
create trigger curriculum_topic_touch before update on curriculum_topic
  for each row execute function set_updated_at();

-- ---------- bride ----------
create table bride (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references instructor(id) on delete cascade,
  first_name             text not null,
  last_name              text,
  phone                  text,
  city                   text,
  groom_name             text,
  wedding_date           date,
  wedding_date_source    calendar_system not null default 'gregorian',
  referral_source        text,
  status                 bride_status not null default 'lead',
  portal_token_hash      bytea,      -- sha256(token); the token itself is never stored
  portal_token_issued_at timestamptz,
  portal_expires_at      timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  deleted_at             timestamptz
);
create unique index bride_portal_token_hash_key
  on bride (portal_token_hash) where portal_token_hash is not null;
create index bride_tenant_status_idx
  on bride (tenant_id, status) where deleted_at is null;
create index bride_tenant_wedding_idx
  on bride (tenant_id, wedding_date) where deleted_at is null;
create trigger bride_touch before update on bride
  for each row execute function set_updated_at();

-- ---------- course (instance of a curriculum for one bride) ----------
create table course (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references instructor(id) on delete cascade,
  bride_id            uuid not null references bride(id) on delete cascade,
  curriculum_id       uuid references curriculum(id) on delete set null,
  curriculum_snapshot jsonb not null,       -- ADR-0004: frozen at creation
  snapshot_version    smallint not null default 1,
  start_date          date,
  target_end_date     date,                 -- effective deadline = wedding_date - buffer_days
  buffer_days         smallint not null default 14
                        check (buffer_days between 0 and 120),
  agreed_price        numeric(10,2) check (agreed_price >= 0),
  status              course_status not null default 'draft',
  completed_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz
);
create index course_tenant_status_idx
  on course (tenant_id, status) where deleted_at is null;
create index course_bride_idx on course (bride_id) where deleted_at is null;
create trigger course_touch before update on course
  for each row execute function set_updated_at();

-- ---------- session (visible to the bride) ----------
create table session (
  id                          uuid primary key default gen_random_uuid(),
  tenant_id                   uuid not null references instructor(id) on delete cascade,
  course_id                   uuid not null references course(id) on delete cascade,
  order_index                 smallint not null,
  scheduled_at                timestamptz,   -- null = "טרם נקבע" (plate 02, note 5)
  duration_minutes            smallint not null default 60 check (duration_minutes > 0),
  location                    text,
  status                      session_status not null default 'planned',
  is_pinned                   boolean not null default false,  -- manual edit survives recompute
  rescheduled_from_session_id uuid references session(id) on delete set null,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  deleted_at                  timestamptz
);
create index session_course_order_idx
  on session (course_id, order_index) where deleted_at is null;
create index session_tenant_upcoming_idx
  on session (tenant_id, scheduled_at)
  where deleted_at is null and status = 'planned';
create trigger session_touch before update on session
  for each row execute function set_updated_at();

-- ---------- session_record (NEVER visible to the bride — ADR-0003) ----------
create table session_record (
  session_id        uuid primary key references session(id) on delete cascade,
  tenant_id         uuid not null references instructor(id) on delete cascade,
  covered_topic_ids uuid[] not null default '{}',
  private_note      text,
  needs_review_note text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz
);
create index session_record_review_idx
  on session_record (tenant_id) where needs_review_note is not null and deleted_at is null;
create trigger session_record_touch before update on session_record
  for each row execute function set_updated_at();

-- ---------- material ----------
create table material (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references instructor(id) on delete cascade,
  course_id           uuid references course(id) on delete cascade,
  curriculum_topic_id uuid references curriculum_topic(id) on delete set null,
  kind                material_kind not null,
  title               text not null,
  storage_path        text,
  url                 text,
  shared_with_bride   boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  constraint material_payload_ck check (
    (kind = 'file' and storage_path is not null and url is null) or
    (kind = 'link' and url is not null and storage_path is null)
  )
);
create index material_course_idx on material (course_id) where deleted_at is null;
create trigger material_touch before update on material
  for each row execute function set_updated_at();

-- ---------- payment ----------
create table payment (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references instructor(id) on delete cascade,
  course_id      uuid not null references course(id) on delete cascade,
  amount         numeric(10,2) not null check (amount > 0),
  currency       char(3) not null default 'ILS',
  method         payment_method not null,
  payer          payer_type not null default 'bride',
  paid_at        date not null,
  receipt_number text,
  note           text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index payment_tenant_paid_idx
  on payment (tenant_id, paid_at) where deleted_at is null;
create index payment_course_idx on payment (course_id) where deleted_at is null;
create trigger payment_touch before update on payment
  for each row execute function set_updated_at();

-- ---------- messaging ----------
create table message_template (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references instructor(id) on delete cascade,
  name       text not null,
  body       text not null,     -- variables are parsed from {{...}}, not stored separately
  is_system  boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index message_template_tenant_idx
  on message_template (tenant_id) where deleted_at is null;
create trigger message_template_touch before update on message_template
  for each row execute function set_updated_at();

create table message_log (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references instructor(id) on delete cascade,
  bride_id      uuid not null references bride(id) on delete cascade,
  session_id    uuid references session(id) on delete set null,
  channel       message_channel not null,
  template_id   uuid references message_template(id) on delete set null,
  rendered_body text not null,
  status        message_status not null default 'composed',  -- ADR-0007: not 'sent'
  composed_at   timestamptz not null default now()
);
create index message_log_bride_idx on message_log (bride_id, composed_at desc);

-- ---------- blackout dates (instructor-declared unavailability) ----------
create table blackout_date (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references instructor(id) on delete cascade,
  starts_on  date not null,
  ends_on    date not null,
  reason     text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint blackout_range_ck check (ends_on >= starts_on)
);
create index blackout_tenant_range_idx
  on blackout_date (tenant_id, starts_on, ends_on) where deleted_at is null;
create trigger blackout_touch before update on blackout_date
  for each row execute function set_updated_at();

-- ---------- access_log (append-only; §10.1) ----------
-- No FK to bride: the log must survive hard deletion of bride data.
-- Stores identifiers and actions only — never personal content.
create table access_log (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null,
  actor_kind  text not null check (actor_kind in ('instructor','bride_portal','system','support')),
  actor_id    uuid,
  bride_id    uuid,
  action      text not null,
  resource    text not null,
  request_id  text,
  ip_hash     bytea,
  occurred_at timestamptz not null default now()
);
create index access_log_tenant_time_idx on access_log (tenant_id, occurred_at desc);
create index access_log_bride_time_idx  on access_log (bride_id, occurred_at desc);

-- =============================================================
-- Views
-- security_invoker = on is MANDATORY: without it a view runs with the
-- owner's privileges and silently bypasses the caller's RLS.
-- =============================================================

-- The ONLY relation the bride portal may read for sessions.
-- session_record is not reachable from here by construction.
create view portal_session_view with (security_invoker = on) as
select
  s.id,
  c.bride_id,
  s.order_index,
  s.scheduled_at,
  s.duration_minutes,
  s.location,
  s.status
from session s
join course c on c.id = s.course_id
where s.deleted_at is null
  and c.deleted_at is null;

-- Risk ranking for the Today screen (§9). Computed on read — never stored,
-- so the ranking cannot go stale.
create view v_course_risk with (security_invoker = on) as
with agg as (
  select
    c.id              as course_id,
    c.tenant_id       as tenant_id,
    c.bride_id        as bride_id,
    c.target_end_date as target_end_date,
    b.wedding_date    as wedding_date,
    count(s.id) filter (where s.status = 'planned')            as sessions_remaining,
    count(s.id) filter (where s.status = 'done')               as sessions_done,
    max(s.scheduled_at) filter (where s.status = 'done')       as last_done_at,
    count(s.id) filter (
      where s.status = 'cancelled'
        and s.scheduled_at < now() - interval '7 days'
        and not exists (
          select 1 from session r
          where r.rescheduled_from_session_id = s.id
            and r.deleted_at is null
        )
    ) as stale_cancellations
  from course c
  join bride b on b.id = c.bride_id
  left join session s on s.course_id = c.id and s.deleted_at is null
  where c.deleted_at is null
    and c.status = 'active'
  group by c.id, c.tenant_id, c.bride_id, c.target_end_date, b.wedding_date
)
select
  agg.course_id,
  agg.tenant_id,
  agg.bride_id,
  agg.sessions_remaining,
  agg.sessions_done,
  agg.last_done_at,
  agg.stale_cancellations,
  agg.target_end_date,
  agg.wedding_date,
  greatest(0, agg.target_end_date - current_date) as days_to_deadline,
  case
    when agg.sessions_remaining >
         floor(greatest(0, agg.target_end_date - current_date) / 7.0)
      then 'critical'
    when agg.stale_cancellations > 0
      then 'high'
    when agg.last_done_at is not null
     and agg.last_done_at < now() - interval '21 days'
      then 'medium'
    when agg.wedding_date is not null
     and agg.wedding_date <= current_date + 30
      then 'info'
    else 'none'
  end::risk_level as risk_level,
  case
    when agg.sessions_remaining >
         floor(greatest(0, agg.target_end_date - current_date) / 7.0)
      then 'wont_finish_in_time'
    when agg.stale_cancellations > 0
      then 'cancelled_not_rescheduled'
    when agg.last_done_at is not null
     and agg.last_done_at < now() - interval '21 days'
      then 'no_recent_session'
    when agg.wedding_date is not null
     and agg.wedding_date <= current_date + 30
      then 'wedding_approaching'
    else null
  end as risk_reason_code
from agg;

-- =============================================================
-- Row Level Security (ADR-0002)
-- =============================================================

alter table instructor        enable row level security;
alter table curriculum        enable row level security;
alter table curriculum_topic  enable row level security;
alter table bride             enable row level security;
alter table course            enable row level security;
alter table session           enable row level security;
alter table session_record    enable row level security;
alter table material          enable row level security;
alter table payment           enable row level security;
alter table message_template  enable row level security;
alter table message_log       enable row level security;
alter table blackout_date     enable row level security;
alter table access_log        enable row level security;

create policy instructor_self on instructor
  for all to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy curriculum_tenant on curriculum
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy curriculum_topic_tenant on curriculum_topic
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy bride_tenant on bride
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy course_tenant on course
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy session_tenant on session
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy session_record_tenant on session_record
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy material_tenant on material
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy payment_tenant on payment
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy message_template_tenant on message_template
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy message_log_tenant on message_log
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

create policy blackout_tenant on blackout_date
  for all to authenticated
  using (tenant_id = auth.uid()) with check (tenant_id = auth.uid());

-- access_log is append-only: insert + read own tenant, never update or delete.
create policy access_log_insert on access_log
  for insert to authenticated with check (tenant_id = auth.uid());
create policy access_log_read on access_log
  for select to authenticated using (tenant_id = auth.uid());

-- ---------- grants ----------
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  instructor, curriculum, curriculum_topic, bride, course, session,
  session_record, material, payment, message_template, message_log,
  blackout_date
  to authenticated;
grant select, insert on access_log to authenticated;
revoke update, delete on access_log from authenticated;
grant select on portal_session_view, v_course_risk to authenticated;
