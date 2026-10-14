# Architecture boundary

1. The authenticated PWA uploads a ZIP to a server endpoint.
2. The server validates the upload, calculates its SHA-256, saves it in a private storage bucket, and creates an import record.
3. The server invokes an internal authenticated n8n webhook with the import ID. Browser code never receives the internal webhook secret or a Supabase server key.
4. n8n loads the private archive, checks ZIP limits, decompresses with the built-in Compression node, and parses supported WhatsApp text-export files.
5. Each parsed message is stored as an immutable source occurrence with group, timestamp text, sender text, filename and file/line locator.
6. n8n creates task candidates with evidence IDs. The database status remains unset.
7. The PWA reads through an authenticated server API and lets the user review, merge, assign, and set status manually.

## Retry and duplicate handling

- Archive SHA-256 is unique, so uploading the exact same ZIP returns the existing import.
- Each parsed source locator is unique within its import, so workflow retries do not duplicate evidence rows.
- A WhatsApp message ID, when actually present, is a strong message identity.
- When no message ID exists, compare the group, normalized timestamp, sender and text. Auto-link only a one-to-one match; collisions remain reviewable.
- Similar wording across groups is separate evidence. A user explicitly decides whether two task candidates refer to the same work.

## Privacy and access

- Keep ZIPs and extracted transcript text in private storage.
- RLS is enabled on database tables. No anon/authenticated policies are included in the initial schema; a trusted server performs writes and mediates PWA access.
- Keep server keys in backend/n8n secret storage. Never commit them or chat exports.
- Apply upload and decompression size limits; reject encrypted, corrupt, oversized, or path-traversal archives.
- Retain source evidence so every candidate can be opened back to its export location.
