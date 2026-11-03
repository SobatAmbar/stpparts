-- =====================================================================
-- STP PARTS - SKEMA DATABASE v3 (Supabase / PostgreSQL)
-- Cara pakai: Supabase > SQL Editor > New query > tempel SEMUA isi file ini > Run
-- Aman dijalankan ulang. Untuk pemasangan baru maupun pembaruan dari versi sebelumnya.
-- (Jika struktur tracker versi lama terdeteksi, tabel tracker lama diganti sekali: data uji hilang.)
-- =====================================================================

-- 1) PROFIL PENGGUNA: peran (admin/editor/viewer) + gudang yang boleh diakses ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  role       text not null default 'viewer' check (role in ('admin','editor','viewer')),
  gudang     text[] not null default '{}',
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() $$;

create or replace function public.can_write() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('admin','editor') from public.profiles where id = auth.uid()), false) $$;

create or replace function public.can_gudang(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' or g = any(gudang) from public.profiles where id = auth.uid()), false) $$;

-- 2) TRACKER FOLLOW-UP (v2: Batch MSR, requester, qty diterima, jadwal FU) -----------------
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='followup_items' and column_name='priority') then
    drop view if exists public.followup_summary;
    drop table if exists public.followup_logs cascade;
    drop table if exists public.followup_items cascade;
  end if;
end $$;

create table if not exists public.followup_items (
  id           bigint generated always as identity primary key,
  part         text not null default '',
  descr        text,
  msr          text not null default '',
  vendor       text,
  qty          numeric not null default 1,
  po           text,
  stock_manual numeric,
  status       text not null default 'Belum Diterima' check (status in ('Belum Diterima','Sebagian Diterima','Sudah Diterima')),
  rcv          numeric not null default 0,
  urgent       boolean not null default false,
  next_fu      date,
  reqs         text[] not null default '{}',
  legacy_id    text unique,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.followup_logs (
  id         bigint generated always as identity primary key,
  item_id    bigint not null references public.followup_items(id) on delete cascade,
  log_date   date not null,
  status     text not null check (status in ('Belum Diterima','Sebagian Diterima','Sudah Diterima')),
  po         text,
  note       text not null default '',
  rcv        numeric not null default 0,
  next_fu    date,
  edits      jsonb not null default '[]',        -- jejak perubahan (sebelum -> sesudah)
  imported   boolean not null default false,     -- true = diimpor dari tracker lama
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(), -- cap waktu SERVER
  updated_at timestamptz not null default now()
);
create index if not exists idx_logs_item on public.followup_logs(item_id, log_date, id);

create table if not exists public.requesters (
  name       text primary key,
  created_at timestamptz not null default now()
);
insert into public.requesters(name) values ('BUMA'),('CK'),('ABC') on conflict do nothing;

-- 3) DATABASE STOK ACCURATE (laporan Kuantitas Barang per Gudang) ---------------------------
create table if not exists public.stock_qty (
  kode_norm text primary key,
  kode      text,
  nama      text,
  total     numeric,
  wh        jsonb
);
create table if not exists public.stock_qty_meta (
  id        integer primary key default 1 check (id = 1),
  file      text,
  synced_at timestamptz not null default now(),
  wh        text[],
  items     integer,
  synced_by uuid default auth.uid()
);

create or replace function public.replace_stock_qty(p_reset boolean, p_rows jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.can_write() then raise exception 'tidak diizinkan'; end if;
  if p_reset then delete from public.stock_qty; end if;
  insert into public.stock_qty (kode_norm, kode, nama, total, wh)
  select x.kode_norm, x.kode, x.nama, x.total, x.wh
  from jsonb_to_recordset(p_rows) as x(kode_norm text, kode text, nama text, total numeric, wh jsonb)
  on conflict (kode_norm) do update set kode = excluded.kode, nama = excluded.nama, total = excluded.total, wh = excluded.wh;
  get diagnostics n = row_count;
  return n;
end; $$;

-- 3b) DATA PENJUALAN (ringkasan per part dari laporan Rincian Pesanan Penjualan) & TANDA DEAD STOCK MANUAL
create table if not exists public.sales_summary (
  kode_norm text primary key,
  kode      text,
  nama      text,
  last_date date,
  n_tx      integer,
  qty_total numeric,
  months    jsonb
);
create table if not exists public.sales_meta (
  id        integer primary key default 1 check (id = 1),
  file      text,
  synced_at timestamptz not null default now(),
  rows_file integer,
  rows_used integer,
  parts     integer,
  date_min  date,
  date_max  date,
  synced_by uuid default auth.uid()
);
create table if not exists public.part_flags (
  kode_norm  text primary key,
  dead_stock boolean not null default false,
  note       text,
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now()
);

create or replace function public.replace_sales_summary(p_reset boolean, p_rows jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.can_write() then raise exception 'tidak diizinkan'; end if;
  if p_reset then delete from public.sales_summary; end if;
  insert into public.sales_summary (kode_norm, kode, nama, last_date, n_tx, qty_total, months)
  select x.kode_norm, x.kode, x.nama, x.last_date, x.n_tx, x.qty_total, x.months
  from jsonb_to_recordset(p_rows) as x(kode_norm text, kode text, nama text, last_date date, n_tx integer, qty_total numeric, months jsonb)
  on conflict (kode_norm) do update set kode = excluded.kode, nama = excluded.nama, last_date = excluded.last_date,
    n_tx = excluded.n_tx, qty_total = excluded.qty_total, months = excluded.months;
  get diagnostics n = row_count;
  return n;
end; $$;

-- 4) STOK & UMUR PERSEDIAAN PER GUDANG (hasil unggah Aging) ------------------------------
create table if not exists public.stock_uploads (
  id           bigint generated always as identity primary key,
  gudang       text not null check (gudang in ('B','E','F','L','O','C')),
  as_of        date not null,
  filename     text,
  rows_file    integer,
  rows_saved   integer,
  total_stok   numeric,
  total_nilai  numeric,
  rows_selisih integer,
  tanpa_nilai  boolean not null default false,
  uploaded_by  uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  unique (gudang, as_of)
);
create table if not exists public.stock_rows (
  id           bigint generated always as identity primary key,
  upload_id    bigint not null references public.stock_uploads(id) on delete cascade,
  gudang       text not null,
  as_of        date not null,
  kode         text not null,
  nama         text,
  satuan       text,
  kategori     text,
  nilai_satuan numeric default 0,
  nilai_total  numeric default 0,
  stok         numeric default 0,
  b1 numeric default 0, b2 numeric default 0, b3 numeric default 0, b4 numeric default 0, b5 numeric default 0,
  selisih      numeric default 0,
  unique (upload_id, kode)
);
create index if not exists idx_rows_upload on public.stock_rows(upload_id);

-- 5) JEJAK AUDIT -----------------------------------------------------------------------
create table if not exists public.audit_log (
  id         bigint generated always as identity primary key,
  table_name text, row_id text, action text,
  old_data   jsonb, new_data jsonb,
  changed_by uuid default auth.uid(),
  changed_at timestamptz not null default now()
);

create or replace function public.audit_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (table_name, row_id, action, old_data, new_data)
  values (tg_table_name, coalesce(new.id, old.id)::text, tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end; $$;

drop trigger if exists audit_items on public.followup_items;
create trigger audit_items after insert or update or delete on public.followup_items for each row execute function public.audit_trigger();
drop trigger if exists audit_logs on public.followup_logs;
create trigger audit_logs after insert or update or delete on public.followup_logs for each row execute function public.audit_trigger();
drop trigger if exists audit_uploads on public.stock_uploads;
create trigger audit_uploads after insert or update or delete on public.stock_uploads for each row execute function public.audit_trigger();

create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists trg_items_updated on public.followup_items;
create trigger trg_items_updated before update on public.followup_items for each row execute function public.set_updated_at();
drop trigger if exists trg_logs_updated on public.followup_logs;
create trigger trg_logs_updated before update on public.followup_logs for each row execute function public.set_updated_at();

-- 6) KEAMANAN (Row Level Security) ----------------------------------------------------
alter table public.profiles       enable row level security;
alter table public.followup_items enable row level security;
alter table public.followup_logs  enable row level security;
alter table public.requesters     enable row level security;
alter table public.stock_qty      enable row level security;
alter table public.stock_qty_meta enable row level security;
alter table public.sales_summary  enable row level security;
alter table public.sales_meta     enable row level security;
alter table public.part_flags     enable row level security;
alter table public.stock_uploads  enable row level security;
alter table public.stock_rows     enable row level security;
alter table public.audit_log      enable row level security;

drop policy if exists p_profiles_sel on public.profiles;
drop policy if exists p_profiles_upd on public.profiles;
create policy p_profiles_sel on public.profiles for select to authenticated using (true);
create policy p_profiles_upd on public.profiles for update to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists p_items_sel on public.followup_items;
drop policy if exists p_items_ins on public.followup_items;
drop policy if exists p_items_upd on public.followup_items;
drop policy if exists p_items_del on public.followup_items;
create policy p_items_sel on public.followup_items for select to authenticated using (true);
create policy p_items_ins on public.followup_items for insert to authenticated with check (public.can_write() and created_by = auth.uid());
create policy p_items_upd on public.followup_items for update to authenticated using (public.can_write()) with check (public.can_write());
create policy p_items_del on public.followup_items for delete to authenticated using (public.my_role() = 'admin');

drop policy if exists p_logs_sel on public.followup_logs;
drop policy if exists p_logs_ins on public.followup_logs;
drop policy if exists p_logs_upd on public.followup_logs;
drop policy if exists p_logs_del on public.followup_logs;
create policy p_logs_sel on public.followup_logs for select to authenticated using (true);
create policy p_logs_ins on public.followup_logs for insert to authenticated with check (public.can_write() and created_by = auth.uid());
create policy p_logs_upd on public.followup_logs for update to authenticated using (public.can_write()) with check (public.can_write());
create policy p_logs_del on public.followup_logs for delete to authenticated using (public.my_role() = 'admin');

drop policy if exists p_req_sel on public.requesters;
drop policy if exists p_req_ins on public.requesters;
drop policy if exists p_req_del on public.requesters;
create policy p_req_sel on public.requesters for select to authenticated using (true);
create policy p_req_ins on public.requesters for insert to authenticated with check (public.can_write());
create policy p_req_del on public.requesters for delete to authenticated using (public.can_write());

drop policy if exists p_sq_sel on public.stock_qty;
create policy p_sq_sel on public.stock_qty for select to authenticated using (true);
drop policy if exists p_sqm_sel on public.stock_qty_meta;
drop policy if exists p_sqm_ins on public.stock_qty_meta;
drop policy if exists p_sqm_upd on public.stock_qty_meta;
create policy p_sqm_sel on public.stock_qty_meta for select to authenticated using (true);
create policy p_sqm_ins on public.stock_qty_meta for insert to authenticated with check (public.can_write());
create policy p_sqm_upd on public.stock_qty_meta for update to authenticated using (public.can_write()) with check (public.can_write());

drop policy if exists p_ss_sel on public.sales_summary;
create policy p_ss_sel on public.sales_summary for select to authenticated using (true);
drop policy if exists p_sm_sel on public.sales_meta;
drop policy if exists p_sm_ins on public.sales_meta;
drop policy if exists p_sm_upd on public.sales_meta;
create policy p_sm_sel on public.sales_meta for select to authenticated using (true);
create policy p_sm_ins on public.sales_meta for insert to authenticated with check (public.can_write());
create policy p_sm_upd on public.sales_meta for update to authenticated using (public.can_write()) with check (public.can_write());
drop policy if exists p_pf_sel on public.part_flags;
drop policy if exists p_pf_ins on public.part_flags;
drop policy if exists p_pf_upd on public.part_flags;
drop policy if exists p_pf_del on public.part_flags;
create policy p_pf_sel on public.part_flags for select to authenticated using (true);
create policy p_pf_ins on public.part_flags for insert to authenticated with check (public.can_write());
create policy p_pf_upd on public.part_flags for update to authenticated using (public.can_write()) with check (public.can_write());
create policy p_pf_del on public.part_flags for delete to authenticated using (public.can_write());

drop policy if exists p_upl_sel on public.stock_uploads;
drop policy if exists p_upl_ins on public.stock_uploads;
drop policy if exists p_upl_del on public.stock_uploads;
create policy p_upl_sel on public.stock_uploads for select to authenticated using (public.can_gudang(gudang));
create policy p_upl_ins on public.stock_uploads for insert to authenticated
  with check (public.can_write() and public.can_gudang(gudang) and uploaded_by = auth.uid());
create policy p_upl_del on public.stock_uploads for delete to authenticated using (public.can_write() and public.can_gudang(gudang));

drop policy if exists p_rows_sel on public.stock_rows;
drop policy if exists p_rows_ins on public.stock_rows;
create policy p_rows_sel on public.stock_rows for select to authenticated using (public.can_gudang(gudang));
create policy p_rows_ins on public.stock_rows for insert to authenticated with check (public.can_write() and public.can_gudang(gudang));

drop policy if exists p_audit_sel on public.audit_log;
create policy p_audit_sel on public.audit_log for select to authenticated using (public.my_role() = 'admin');

-- 7) IZIN AKSES ---------------------------------------------------------------------------
revoke all on public.profiles, public.followup_items, public.followup_logs, public.requesters, public.stock_qty,
              public.sales_summary, public.sales_meta, public.part_flags, public.stock_qty_meta, public.stock_uploads, public.stock_rows, public.audit_log from anon;
grant select, update                 on public.profiles        to authenticated;
grant select, insert, update, delete on public.followup_items  to authenticated;
grant select, insert, update, delete on public.followup_logs   to authenticated;
grant select, insert, delete         on public.requesters      to authenticated;
grant select                         on public.stock_qty       to authenticated;
grant select, insert, update         on public.stock_qty_meta  to authenticated;
grant select                         on public.sales_summary   to authenticated;
grant select, insert, update         on public.sales_meta      to authenticated;
grant select, insert, update, delete on public.part_flags      to authenticated;
revoke execute on function public.replace_sales_summary(boolean, jsonb) from public, anon;
grant execute on function public.replace_sales_summary(boolean, jsonb) to authenticated;
grant select, insert, delete         on public.stock_uploads   to authenticated;
grant select, insert                 on public.stock_rows      to authenticated;
grant select                         on public.audit_log       to authenticated;
revoke execute on function public.replace_stock_qty(boolean, jsonb) from public, anon;
grant execute on function public.replace_stock_qty(boolean, jsonb) to authenticated;

-- 8) PING (opsional: dipakai keepalive; tidak membuka data apa pun)
create or replace function public.ping() returns text language sql stable as $$ select 'ok'::text $$;
grant execute on function public.ping() to anon, authenticated;

-- SELESAI. Pemasangan baru: buat akun pertama (Authentication > Users > Add user), lalu jadikan admin:
--   update public.profiles set role = 'admin' where email = 'email.anda@perusahaan.com';
