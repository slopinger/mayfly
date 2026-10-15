# mayfly development notes

Gleam/Erlang temporary file host. All app logic is in `src/mayfly.gleam` and
`src/mayfly/store.gleam`; `src/mayfly_clock.erl` is a clock-only FFI wrapper.
Wisp/Mist stream multipart files and downloads. Vanilla frontend is `priv/web/`.

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
