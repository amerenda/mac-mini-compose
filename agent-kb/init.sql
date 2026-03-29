-- Agent KB schema initialization
-- Run once on first container start via /docker-entrypoint-initdb.d/

CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- Memory records — all agent knowledge
-- ============================================================
CREATE TABLE memory_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    content         TEXT NOT NULL,
    embedding       vector(384),        -- all-MiniLM-L6-v2 dimensions
    scope           TEXT NOT NULL,       -- hierarchical path
    categories      TEXT[] DEFAULT '{}',
    metadata        JSONB DEFAULT '{}',
    importance      REAL DEFAULT 0.5,    -- 0.0 to 1.0
    source          TEXT,                -- which agent/run created this
    private         BOOLEAN DEFAULT FALSE,
    needs_embedding BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT now(),
    last_accessed   TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_memory_scope ON memory_records USING btree (scope);
CREATE INDEX idx_memory_categories ON memory_records USING gin (categories);
CREATE INDEX idx_memory_created ON memory_records (created_at DESC);
-- ivfflat index created after data exists (needs rows to train on)
-- Run manually after seeding: CREATE INDEX idx_memory_embedding ON memory_records USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ============================================================
-- Agent tasks — coordinator state
-- ============================================================
CREATE TABLE agent_tasks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_type      TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    trigger         TEXT NOT NULL,
    trigger_ref     TEXT,
    config          JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT now(),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    result          JSONB
);

CREATE INDEX idx_tasks_status ON agent_tasks (status);
CREATE INDEX idx_tasks_agent_type ON agent_tasks (agent_type);
CREATE INDEX idx_tasks_created ON agent_tasks (created_at DESC);

-- ============================================================
-- Trigger rules — event routing
-- ============================================================
CREATE TABLE trigger_rules (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    event_type      TEXT NOT NULL,
    event_filter    JSONB DEFAULT '{}',
    agent_type      TEXT NOT NULL,
    enabled         BOOLEAN DEFAULT TRUE,
    config          JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- Argo Workflows persistence (separate database)
-- ============================================================
SELECT 'CREATE DATABASE argo_workflows'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'argo_workflows')\gexec
