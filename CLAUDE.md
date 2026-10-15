# boymoder slop box development notes

Gleam/Erlang temporary file host. All app logic is in `src/boymoder_slop_box.gleam` and
`src/boymoder_slop_box/store.gleam`; `src/boymoder_slop_box_clock.erl` is a clock-only FFI wrapper.
Wisp/Mist stream multipart files and downloads. Vanilla frontend is `priv/web/`.
The UI is a compact upload panel with collapsed service/API details and original
transparent corner mascots at `priv/web/mascot-*.png` (prompts in `docs/artwork.md`).
Keep them small, muted and pointer-events:none, outside the controls. Tab-local
sessionStorage excludes the previous variant on each reload; no personal data.

- `gleam format --check src test`; `gleam test`; `gleam export erlang-shipment`;
  `python3 test/http_test.py`. HTTP fixtures use temp storage and free local ports.
- Browser fixture: `test/browser.mjs`, external Playwright/Chromium, see README.
- Storage actor serializes publication/deletion and reserves quota before reading
  bodies. Preserve streaming, size/field/rate/concurrency limits, hashed deletion
  secrets, exact expiry checks and attachment-only downloads.
- Wisp staging is forced into `MAYFLY_DATA/tmp` and cleared on startup; keep it
  on the data filesystem for atomic rename. One process per data directory.
- Loopback binding is required. Caddy MUST overwrite X-Real-IP; no access log.
- Deploy committed source with `./deploy.sh`; shipped BEAM at `/opt/mayfly/current`,
  service `mayfly`, loopback 8791, data `/var/lib/mayfly`. Uploads have no backups.
- Update README and `/home/slop/CLAUDE.md` when behavior or operations change.
- Signed commits, public MIT GitLab under slop, never commit uploads/secrets.

- Gleam package: `boymoder_slop_box`. URL, repo path, service/user/data paths and
  `MAYFLY_*` settings retain legacy names for upgrade/link compatibility.
- Branding: original code-native `priv/web/logo.svg` + `favicon.svg`; display name
  is “boymoder slop box”. Keep the page title, logo alt text and homepage card in sync.
