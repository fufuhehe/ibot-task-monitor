# TaskMonitor upload PWA (preview)

A small installable upload page for the imported n8n workflow **TaskMonitor - WhatsApp ZIP Parser Preview**. It sends one WhatsApp ZIP to the workflow's temporary **Test URL** and renders the JSON preview. It does not store chat exports, write to Supabase, or make tasks.

## Try it locally

Serve this folder over HTTPS or localhost (service workers do not run on `file://`). For example, with any static local server, open its `pwa/` root in a browser. In another tab, open n8n and:

1. Open the imported preview workflow.
2. In **Receive ZIP**, click **Test URL**, then **Listen for Test Event**.
3. Copy the Test URL into the PWA, enter the exact WhatsApp group title, select its ZIP, and choose **Unggah dan periksa**.
4. Review the parsed count and sample rows against the source export.

If the browser reports a network/CORS error, verify the test listener is active and the copied URL is exact. Keep this test URL private. The parser preview contains message excerpts.

## Deploy the static PWA

Deploy this folder as the static site root on a HTTPS host. If using a host that builds the full repository, set its project root to `pwa/`. The app shell can be installed from the browser's install menu.

## Before production

This is only a preview uploader. It calls an unauthenticated, temporary n8n test webhook from the browser. **Do not activate or expose a production webhook from this page.** A production PWA needs an authenticated backend that validates the user and ZIP, computes SHA-256, stores the archive in the private Supabase bucket, creates an import record, and calls the internal n8n workflow. Browser code must never contain a Supabase service-role/secret key or n8n webhook secret.

The server-side upload pipeline described in `../docs/architecture.md` remains the production target. This client deliberately avoids local storage, analytics, and caching of upload responses.
