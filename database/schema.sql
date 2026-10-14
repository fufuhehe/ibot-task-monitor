-- TaskMonitor v1 logical storage schema (PostgreSQL 15+)
-- Apply to a dedicated database/schema. Do not store WhatsApp credentials here.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE import_state AS ENUM ('uploaded', 'processing', 'review_required', 'completed', 'failed');
CREATE TYPE group_scope AS ENUM ('main', 'activity', 'unclassified');
CREATE TYPE task_review_state AS ENUM ('candidate', 'confirmed', 'needs_context', 'rejected');
CREATE TYPE task_status AS ENUM ('not_started', 'in_progress', 'waiting', 'done', 'cancelled');
CREATE TYPE person_role AS ENUM ('team_lead', 'pic', 'member', 'unconfirmed');
CREATE TYPE task_person_role AS ENUM ('assigner', 'assignee', 'supervisor', 'mentioned');
CREATE TYPE evidence_relation AS ENUM ('assignment', 'request', 'context', 'deadline', 'follow_up', 'other');
CREATE TYPE occurrence_resolution AS ENUM ('unresolved', 'same_message', 'distinct_message');

CREATE TABLE source_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_name text NOT NULL,
  whatsapp_group_id text,
  scope group_scope NOT NULL DEFAULT 'unclassified',
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text,
  CONSTRAINT source_group_id_nonempty CHECK (whatsapp_group_id IS NULL OR length(whatsapp_group_id) > 0)
);
CREATE UNIQUE INDEX source_groups_wa_id_uq ON source_groups (whatsapp_group_id) WHERE whatsapp_group_id IS NOT NULL;
CREATE INDEX source_groups_name_idx ON source_groups (lower(group_name));

CREATE TABLE people (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text NOT NULL,
  role person_role NOT NULL DEFAULT 'unconfirmed',
  identity_basis text NOT NULL CHECK (identity_basis IN ('user_provided', 'explicit_source', 'manual_confirmation')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (display_name)
);

CREATE TABLE activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text NOT NULL,
  confirmation_state text NOT NULL DEFAULT 'unconfirmed' CHECK (confirmation_state IN ('unconfirmed', 'confirmed')),
  confirmed_by text,
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((confirmation_state = 'confirmed' AND confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL)
      OR confirmation_state = 'unconfirmed')
);
CREATE UNIQUE INDEX activities_confirmed_name_uq ON activities (lower(display_name)) WHERE confirmation_state = 'confirmed';

CREATE TABLE imports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_group_id uuid REFERENCES source_groups(id),
  original_filename text NOT NULL,
  archive_sha256 char(64) NOT NULL UNIQUE,
  storage_key text NOT NULL,
  uploaded_by text NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  state import_state NOT NULL DEFAULT 'uploaded',
  parser_version text,
  started_at timestamptz,
  finished_at timestamptz,
  source_message_count integer NOT NULL DEFAULT 0 CHECK (source_message_count >= 0),
  duplicate_occurrence_count integer NOT NULL DEFAULT 0 CHECK (duplicate_occurrence_count >= 0),
  error_code text,
  error_summary text,
  CHECK ((state IN ('processing') AND started_at IS NOT NULL)
      OR state <> 'processing')
);
CREATE INDEX imports_state_uploaded_idx ON imports (state, uploaded_at);

-- One row per parsed line/message in one uploaded export. This is the immutable evidence ledger.
CREATE TABLE message_occurrences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  import_id uuid NOT NULL REFERENCES imports(id) ON DELETE RESTRICT,
  source_group_id uuid NOT NULL REFERENCES source_groups(id),
  source_locator text NOT NULL,
  whatsapp_message_id text,
  sent_at_raw text NOT NULL,
  sent_at timestamptz,
  sender_name_raw text,
  sender_identity_id uuid REFERENCES people(id),
  message_kind text NOT NULL DEFAULT 'unknown' CHECK (message_kind IN ('text', 'media', 'system', 'unknown')),
  text_raw text,
  media_names jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(media_names) = 'array'),
  normalized_fingerprint char(64),
  parsed_at timestamptz NOT NULL DEFAULT now(),
  parse_notes text,
  resolved_message_id uuid,
  resolution occurrence_resolution NOT NULL DEFAULT 'unresolved',
  UNIQUE (import_id, source_locator),
  CHECK (whatsapp_message_id IS NULL OR length(whatsapp_message_id) > 0),
  CHECK (resolution <> 'same_message' OR resolved_message_id IS NOT NULL)
);
CREATE INDEX message_occurrences_group_time_idx ON message_occurrences (source_group_id, sent_at);
CREATE INDEX message_occurrences_fingerprint_idx ON message_occurrences (source_group_id, normalized_fingerprint) WHERE normalized_fingerprint IS NOT NULL;
CREATE INDEX message_occurrences_import_idx ON message_occurrences (import_id);

-- Canonical messages are created only when identity is certain (WhatsApp ID), or after a human resolves
-- a fingerprint collision. Cross-group messages are never auto-merged.
CREATE TABLE messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_group_id uuid NOT NULL REFERENCES source_groups(id),
  whatsapp_message_id text,
  canonical_occurrence_id uuid NOT NULL UNIQUE REFERENCES message_occurrences(id) ON DELETE RESTRICT,
  identity_method text NOT NULL CHECK (identity_method IN ('whatsapp_message_id', 'human_confirmed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_group_id, whatsapp_message_id)
);
ALTER TABLE message_occurrences ADD CONSTRAINT occurrence_resolved_message_fk
  FOREIGN KEY (resolved_message_id) REFERENCES messages(id) ON DELETE RESTRICT;

CREATE TABLE duplicate_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  left_occurrence_id uuid NOT NULL REFERENCES message_occurrences(id) ON DELETE RESTRICT,
  right_occurrence_id uuid NOT NULL REFERENCES message_occurrences(id) ON DELETE RESTRICT,
  resolution occurrence_resolution NOT NULL DEFAULT 'unresolved',
  resolved_by text,
  resolved_at timestamptz,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (left_occurrence_id <> right_occurrence_id),
  CHECK ((resolution = 'unresolved' AND resolved_by IS NULL AND resolved_at IS NULL)
      OR (resolution <> 'unresolved' AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL))
);
CREATE UNIQUE INDEX duplicate_reviews_pair_uq ON duplicate_reviews
  (LEAST(left_occurrence_id, right_occurrence_id), GREATEST(left_occurrence_id, right_occurrence_id));

CREATE TABLE tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activity_id uuid REFERENCES activities(id),
  activity_label_candidate text,
  task_text text NOT NULL,
  review_state task_review_state NOT NULL DEFAULT 'candidate',
  status task_status, -- NULL until a user deliberately chooses a status.
  status_updated_by text,
  status_updated_at timestamptz,
  deadline_as_written text,
  deadline_at timestamptz,
  deadline_confirmed boolean NOT NULL DEFAULT false,
  created_from text NOT NULL DEFAULT 'human_review' CHECK (created_from IN ('ai_candidate', 'human_review')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL,
  CHECK ((status IS NULL AND status_updated_by IS NULL AND status_updated_at IS NULL)
      OR (status IS NOT NULL AND status_updated_by IS NOT NULL AND status_updated_at IS NOT NULL)),
  CHECK (deadline_at IS NULL OR deadline_confirmed = true),
  CHECK (activity_id IS NULL OR activity_label_candidate IS NULL)
);
CREATE INDEX tasks_review_status_idx ON tasks (review_state, status, updated_at DESC);
CREATE INDEX tasks_activity_idx ON tasks (activity_id, updated_at DESC);

CREATE TABLE task_people (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  person_id uuid REFERENCES people(id),
  name_as_written text NOT NULL,
  task_role task_person_role NOT NULL,
  evidence_occurrence_id uuid REFERENCES message_occurrences(id) ON DELETE RESTRICT,
  source_basis text NOT NULL CHECK (source_basis IN ('explicit_source', 'user_confirmation')),
  confirmed_by text,
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((source_basis = 'explicit_source' AND evidence_occurrence_id IS NOT NULL)
      OR (source_basis = 'user_confirmation' AND confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL))
);
CREATE INDEX task_people_task_idx ON task_people (task_id, task_role);

CREATE TABLE task_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  occurrence_id uuid NOT NULL REFERENCES message_occurrences(id) ON DELETE RESTRICT,
  relation evidence_relation NOT NULL DEFAULT 'context',
  linked_by text NOT NULL,
  linked_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (task_id, occurrence_id, relation)
);
CREATE INDEX task_evidence_occurrence_idx ON task_evidence (occurrence_id);

CREATE TABLE task_status_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT,
  old_status task_status,
  new_status task_status NOT NULL,
  changed_by text NOT NULL,
  change_note text,
  changed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX task_status_events_task_idx ON task_status_events (task_id, changed_at DESC);

CREATE TABLE task_merge_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  left_task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT,
  right_task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT,
  decision text NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'merge', 'keep_separate')),
  decided_by text,
  decided_at timestamptz,
  decision_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (left_task_id <> right_task_id),
  CHECK ((decision = 'pending' AND decided_by IS NULL AND decided_at IS NULL)
      OR (decision <> 'pending' AND decided_by IS NOT NULL AND decided_at IS NOT NULL))
);
CREATE UNIQUE INDEX task_merge_pair_uq ON task_merge_reviews
  (LEAST(left_task_id, right_task_id), GREATEST(left_task_id, right_task_id));

-- Retain each model's candidate output and evidence pointers for audit and reprocessing.
CREATE TABLE extraction_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  import_id uuid NOT NULL REFERENCES imports(id) ON DELETE RESTRICT,
  model_name text NOT NULL,
  prompt_version text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  result_state text NOT NULL CHECK (result_state IN ('completed', 'failed')),
  candidate_count integer NOT NULL DEFAULT 0 CHECK (candidate_count >= 0),
  error_summary text
);

-- Supabase: these public-schema tables are server-only in v1. RLS has no client policies;
-- authenticated/anon clients therefore see no rows. The trusted backend/n8n uses server-side
-- credentials and must never expose them to PWA/browser code.
ALTER TABLE source_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE people ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE imports ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_occurrences ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE duplicate_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_people ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_status_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_merge_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE extraction_runs ENABLE ROW LEVEL SECURITY;

-- Create the private archive bucket in Supabase Storage separately if it does not exist:
-- bucket id: taskmonitor-exports, public=false, per-file and allowed-MIME limits configured
-- for the deployment. Leave storage.objects without anon/authenticated policies in v1.

-- Operational invariants for the API/workflows:
-- 1. Never UPDATE message_occurrences text/source fields after parsing; re-import creates new occurrences.
-- 2. Do not auto-resolve fingerprint matches when either side has multiple candidates.
-- 3. Do not auto-link evidence across different source_groups to a single canonical message.
-- 4. AI may INSERT candidate tasks, but may not set tasks.status or status audit fields.
-- 5. Any status change must insert task_status_events in the same transaction, with authenticated actor.
-- 6. Merge tasks only after a user decision; preserve all task_evidence rows and record the review decision.
-- 7. Keep archive_sha256 unique to make identical ZIP uploads idempotent.

