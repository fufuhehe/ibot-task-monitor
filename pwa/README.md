# TaskMonitor upload PWA (preview)

A small installable upload page for the imported n8n workflow **TaskMonitor - WhatsApp ZIP Parser Preview**. It sends one WhatsApp ZIP to the workflow's temporary **Test URL** and renders the JSON preview. It does not store chat exports, write to Supabase, or make tasks.

## Publish and open the preview

The repository includes a GitHub Actions workflow that publishes only the site entry page and the pwa/ files. One-time setup by a repository admin:

1. Open the repository **Settings → Pages**.
2. Under **Build and deployment → Source**, select **GitHub Actions**.
3. Merge the PWA PR into main. The deployment starts automatically; later changes to the PWA deploy on pushes to main.
4. In **Actions**, open **Deploy TaskMonitor preview to GitHub Pages** and wait for its deploy job to succeed.
5. Open https://fufuhehe.github.io/ibot-task-monitor/. The root page redirects to /pwa/. HTTPS is required for installation/service-worker support.

## Test one WhatsApp ZIP

1. Open the imported n8n preview workflow.
2. In **Receive ZIP**, select **Test URL**, then click **Listen for Test Event**.
3. In the PWA, paste that temporary Test URL, enter the exact WhatsApp group title, select the ZIP, then choose **Unggah dan periksa**.
4. Review the parsed count and sample rows against the source export.

If the browser reports a network/CORS error, verify that the test listener is active and the URL is exact. Keep the Test URL private. The parser preview contains message excerpts. Stop the test listener when done.

## Scope and production boundary

This is only a preview uploader. It calls an unauthenticated, temporary n8n test webhook from the browser. **Do not use a Production URL here or activate/expose a production webhook.** The preview does not write to Supabase or persist tasks. Production needs an authenticated backend that validates the user and ZIP, computes SHA-256, stores the archive in the private Supabase bucket, creates an import record, and calls n8n server-side. Browser code must never contain a Supabase service-role/secret key or n8n webhook secret.

The server-side upload pipeline described in ../docs/architecture.md remains the production target. This client deliberately avoids local storage, analytics, and caching of upload responses.