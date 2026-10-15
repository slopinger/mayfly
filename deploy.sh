#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ -n $(git status --porcelain) ]]; then
  echo 'Commit source before deploying an identifiable release.' >&2
  exit 1
fi
gleam format --check src test
gleam test
gleam export erlang-shipment
python3 test/http_test.py
revision=$(git rev-parse HEAD)
release="/opt/mayfly/releases/$revision"
config=/etc/caddy/conf.d/mayfly.freifick.net.caddy
sudo install -d -m 0755 /opt/mayfly/releases
if ! sudo test -d "$release"; then
  sudo cp -r build/erlang-shipment "$release"
  sudo chown -R root:root "$release"
  sudo chmod -R go-w "$release"
fi
sudo install -Dm644 deploy/mayfly.sysusers /etc/sysusers.d/mayfly.conf
sudo systemd-sysusers /etc/sysusers.d/mayfly.conf
backup=$(mktemp -d)
trap 'rm -rf "$backup"' EXIT
had_config=false
had_unit=false
if sudo test -f "$config"; then sudo cp "$config" "$backup/caddy"; had_config=true; fi
if sudo test -f /etc/systemd/system/mayfly.service; then sudo cp /etc/systemd/system/mayfly.service "$backup/unit"; had_unit=true; fi
previous=$(readlink /opt/mayfly/current || true)
rollback() {
  echo 'Deployment failed; restoring previous service and Caddy configuration.' >&2
  if "$had_config"; then sudo cp "$backup/caddy" "$config"; else sudo rm -f "$config"; fi
  if "$had_unit"; then sudo cp "$backup/unit" /etc/systemd/system/mayfly.service; fi
  if [[ -n "$previous" ]]; then
    sudo ln -sfn "$previous" /opt/mayfly/current.new
    sudo mv -Tf /opt/mayfly/current.new /opt/mayfly/current
    sudo systemctl daemon-reload
    sudo systemctl restart mayfly
  else
    sudo systemctl disable --now mayfly || true
  fi
  sudo systemctl reload caddy
  exit 1
}
sudo install -m644 deploy/mayfly.caddy "$config"
if ! sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then rollback; fi
sudo install -m644 deploy/mayfly.service /etc/systemd/system/mayfly.service
sudo ln -sfn "$release" /opt/mayfly/current.new
sudo mv -Tf /opt/mayfly/current.new /opt/mayfly/current
sudo systemctl daemon-reload
sudo systemctl enable mayfly
if ! sudo systemctl restart mayfly; then rollback; fi
ready=false
for attempt in {1..30}; do
  if curl -fsS http://127.0.0.1:8791/healthz >/dev/null; then ready=true; break; fi
  sleep 1
done
if ! "$ready"; then rollback; fi
if ! sudo systemctl reload caddy; then rollback; fi
printf 'Deployed %s at https://mayfly.freifick.net\n' "$revision"
