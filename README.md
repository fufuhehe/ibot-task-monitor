# TaskMonitor

A private task review app that turns uploaded WhatsApp chat exports into evidence-linked task candidates.

## Components

- **PWA:** upload ZIP exports, review candidates, inspect their source evidence, and manage tasks.
- **Server workflow:** n8n orchestrates import processing and candidate extraction.
- **Data layer:** Supabase Postgres and private object storage.

## Current structure

- `database/schema.sql` — initial Postgres data model with RLS enabled and no browser-facing policies.
- `contracts/task-candidate.schema.json` — structured output contract for candidate extraction.
- `docs/architecture.md` — upload and processing boundary.

The initial schema is a design artifact. Apply it only through a reviewed Supabase migration after confirming the target project and server access model.

## Data rules

- Preserve the original archive and source metadata for every imported message.
- Re-uploaded archives must be idempotent.
- Keep ambiguous duplicate messages and possible cross-group task matches for human review.
- AI creates task candidates with source references. A human decides task validity, activity, assignment, and status.
- Candidate extraction must never set task status or claim progress as fact.
- Keep WhatsApp exports, chat text, credentials, encryption keys, and service secrets out of Git.

## n8n

No n8n connector is configured for the development assistant. Workflows are maintained as exportable JSON and imported into the n8n instance by an administrator. Never put n8n credentials or webhook secrets in workflow exports.
