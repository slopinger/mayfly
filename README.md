# mayfly

**little files, brief lives.** An independently written, MIT-licensed temporary
file host inspired by Litterbox. Written in **Gleam**, running on Erlang/OTP with
Wisp and Mist. A tiny handwritten Erlang FFI exposes the system clock; all
application and storage logic lives in Gleam. Browser enhancement uses vanilla JS.

Live: https://mayfly.freifick.net · Source: https://git.freifick.net/slop/mayfly

## Features

- Anonymous, one-file uploads up to 200 MiB, streamed to disk in 64 KiB chunks.
- Lifetimes of 1, 12, 24 or 72 hours; downloads stop at expiry, disk cleanup every minute.
- Random 128-bit unlisted links, private deletion capabilities (only hashes stored).
- Litterbox-style multipart endpoint plus JSON API; works from curl or a browser.
- Drag/drop, progress, copy link, local expiry display and early deletion.
- Plain HTML form works without JS (returns JSON). No external fonts/assets/trackers.
- A compact upload panel, starfield, beveled window and original anime illustration.
- Service/API notes stay in collapsed details; mobile puts the upload form first.
- Persistent disk metadata, 10 GiB storage quota, four simultaneous uploads,
  20 upload attempts/hour/IP. Requests with an Origin must match MAYFLY_URL.

Not affiliated with Catbox. This is an alternative implementation, not a complete
clone: one file/request, no URL imports, no accounts or permanent storage.
Downloads are attachments, including images. Links are public to anyone who has
them; do not upload secrets. Expiry stops new requests; a download started before
expiry may finish. Uploads are ephemeral and deliberately excluded from backups.

## Run locally

Install Gleam >=1.19, Erlang/OTP >=27 and rebar3. Then:

```sh
gleam deps download
gleam run
```

Visit http://127.0.0.1:8791. Configuration:

| Variable | Default | Meaning |
| --- | --- | --- |
| MAYFLY_DATA | `./data` | Persistent data/metadata directory |
| MAYFLY_URL | `http://127.0.0.1:8791` | Canonical external origin; no trailing slash |
| MAYFLY_PORT | `8791` | Port; always binds 127.0.0.1 |

The app trusts `X-Real-IP` only because it binds loopback. Your reverse proxy MUST
overwrite it with the direct client IP, as the included Caddy config does. Do not
expose Mist directly or let arbitrary clients supply this header. Limits reset
on restart. No app access log; in-memory rate data expires after an hour. The
provided Caddy site has no access log. Service errors can appear in journald.

## API

```sh
curl -F reqtype=fileupload -F time=24h -F fileToUpload=@file.zip \
  https://mayfly.freifick.net/resources/internals/api.php
```

Returns a plain download URL. Change the path to `/api/upload` to receive JSON:

```json
{"url":"https://HOST/f/ID","delete_url":"https://HOST/delete/ID/SECRET","expires":1792051200000,"name":"file.zip","size":123}
```

`expires` is Unix epoch **milliseconds**. `time` accepts `1h`, `12h`, `24h`, `72h`
(or the corresponding integer string); default `1h`. `reqtype` defaults to
`fileupload`. The file field can be `fileToUpload` or `file`. Unknown/duplicate
fields and multiple files are rejected. The plain endpoint does not expose a
deletion URL; use JSON when you need early deletion.

```sh
curl -X DELETE 'YOUR_PRIVATE_DELETE_URL'
```

Success is 204; missing/expired links and invalid deletion capabilities return
404. GET on a deletion URL never deletes. Validation errors use 400, oversized
bodies 413, rate limits 429, busy slots/storage failures 503, and quota exhaustion
507. Empty files are rejected. No authenticated/admin HTTP endpoint exists.

## Verify

```sh
gleam format --check src test
gleam test
gleam export erlang-shipment
python3 test/http_test.py
```

The HTTP test launches a disposable production shipment on a free loopback port
with temporary storage, exercises restart/expiry, and streams a 201 MiB rejected
request without allocating it in memory. It never touches live uploads.
`MAYFLY_TEST_TMPDIR=/var/tmp` places fixture data on the persistent filesystem
while the system `/tmp` remains tmpfs, matching the production storage layout.
The deployment script uses this setting.

Optional browser checks, against a disposable instance at port 18792:

```sh
MAYFLY_DATA=/tmp/mayfly-preview MAYFLY_PORT=18792 \
MAYFLY_URL=http://127.0.0.1:18792 build/erlang-shipment/entrypoint.sh run
# In a second shell with Node + Playwright + Chromium available:
PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs \
CHROMIUM_BIN=/path/to/chromium node test/browser.mjs
```

Tests desktop/390px/320px layout and full upload/download/delete. `BASE_URL`
overrides the target. Browser checks write synthetic uploads and delete them.
Screenshots go to `/tmp/mayfly-{width}.png`.

## Deployment and operations

See `deploy/` and `./deploy.sh` for this host's systemd/Caddy setup. Requires sudo,
Gleam, Erlang/OTP and rebar3. Deploy only committed source; tests run first.
Release files are root-owned under `/opt/mayfly/releases/<commit>`, with atomic
`/opt/mayfly/current` switch. The hardened `mayfly.service` runs as `mayfly`,
listens on 127.0.0.1:8791 and stores uploads/JSON in `/var/lib/mayfly`.
Caddy terminates TLS at mayfly.freifick.net, replacing X-Real-IP. DNS is DNS-only
A/AAAA to this host; provision DNS before deployment. No new public ports.

```sh
sudo systemctl status mayfly
sudo journalctl -u mayfly
curl -fsS https://mayfly.freifick.net/healthz
```

Retain Erlang on the server; the shipment contains compiled application and library
BEAM files, not an embedded runtime. Old releases remain available: stop the
service, switch `/opt/mayfly/current` to an old release, then start it. Metadata
format changes require migration review before rollback.

For abuse removal without the deletion capability: validate that the ID is exactly
32 lowercase hexadecimal characters, stop mayfly, remove only
`/var/lib/mayfly/ID` and `/var/lib/mayfly/ID.json`, then start it. Stopping avoids
racing publication and clears the in-memory index. Never edit metadata while
running. Report abuse with the download URL to slop@freifick.net.

On startup, orphan data files and interrupted `.tmp` metadata are removed.
Metadata and file renames are atomic but not fsync-durable across power loss;
files may disappear early. Storage is bounded at 10 GiB including reservations for
active uploads (plus small metadata/header overhead). Temp files are staged in `MAYFLY_DATA/tmp` on the data filesystem,
so publication can rename atomically even when `/tmp` is tmpfs. Staging is
cleared at startup; run only one process per data directory. The service also
enables PrivateTmp for other temporary files. There is no upload backup or durable availability promise.

## Artwork

`priv/web/anime-girls.png` is original art generated with the built-in imagegen
tool. The final prompt is recorded in [docs/artwork.md](docs/artwork.md). It is
served locally; there are no third-party image requests.
