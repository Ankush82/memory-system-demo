-- Run this in the Supabase SQL editor (Dashboard → SQL Editor → New query)
-- Takes about 5 seconds.

-- 1. Extensions
create extension if not exists vector;

-- 2. Memories
create table if not exists memories (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  type          text not null check (type in ('episodic','semantic','procedural')),
  content       text not null,
  embedding     vector(1536),
  importance    int  not null check (importance between 1 and 10),
  confidence    real not null default 1.0 check (confidence between 0 and 1),
  source        jsonb not null default '{}',
  weight        real not null default 1.0,
  reinforcement int  not null default 0,
  archived      boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- HNSW index (works well with small and large datasets alike)
create index if not exists memories_embedding_idx
  on memories using hnsw (embedding vector_cosine_ops);

create index if not exists memories_fts_idx
  on memories using gin (to_tsvector('english', content));

create index if not exists memories_user_idx
  on memories (user_id);

-- RLS: each user sees only their own rows
alter table memories enable row level security;

create policy "isolation" on memories
  for all using (auth.uid() = user_id);

-- 3. Feedbacks
create table if not exists feedbacks (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  memory_id  uuid references memories(id) on delete cascade,
  signal     text not null check (signal in ('helpful','wrong','outdated','irrelevant')),
  created_at timestamptz not null default now()
);

alter table feedbacks enable row level security;
create policy "isolation" on feedbacks
  for all using (auth.uid() = user_id);

-- 4. Vector similarity search (called via supabase.rpc)
create or replace function match_memories(
  query_embedding vector(1536),
  match_user_id   uuid,
  match_count     int default 20
)
returns table (
  id            uuid,
  content       text,
  type          text,
  importance    int,
  confidence    real,
  weight        real,
  reinforcement int,
  created_at    timestamptz,
  similarity    float
)
language sql stable security definer
as $$
  select
    id, content, type, importance, confidence, weight, reinforcement, created_at,
    1 - (embedding <=> query_embedding) as similarity
  from memories
  where user_id = match_user_id
    and archived = false
    and embedding is not null
  order by embedding <=> query_embedding
  limit match_count;
$$;

-- 5. Full-text search (called via supabase.rpc)
create or replace function search_memories_fts(
  query_text    text,
  match_user_id uuid,
  match_count   int default 20
)
returns table (
  id            uuid,
  content       text,
  type          text,
  importance    int,
  confidence    real,
  weight        real,
  reinforcement int,
  created_at    timestamptz,
  fts_score     float
)
language sql stable security definer
as $$
  select
    id, content, type, importance, confidence, weight, reinforcement, created_at,
    ts_rank(to_tsvector('english', content),
            plainto_tsquery('english', query_text)) as fts_score
  from memories
  where user_id = match_user_id
    and archived = false
    and to_tsvector('english', content) @@ plainto_tsquery('english', query_text)
  order by fts_score desc
  limit match_count;
$$;
