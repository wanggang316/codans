# codans-relay

The relay that lets the codans iOS companion reach a Mac from outside its
network. It is a dumb pipe: it pairs a phone's WebSocket with the Mac's
WebSocket and forwards binary messages verbatim. The phone's TLS-PSK session
runs end to end inside that byte stream, so the relay only ever sees
ciphertext and routing IDs, and it stores only SHA-256 hashes of the Mac
secret and of phone tokens.

The protocol (v1: endpoints, credentials, limits, keepalive) is specified in
[docs/design-docs/ios-companion.md](../../docs/design-docs/ios-companion.md#relay-protocol-v1),
decisions D55–D60.

Relay-specific close codes: `4000` control connection replaced by a newer one,
`4502` the Mac could not be notified or its session upgrade failed, `4504` the
Mac did not open its half of the session within 10 s.

## Run

```bash
go run ./cmd/codans-relay -listen 127.0.0.1:3050 -data ./data
curl http://127.0.0.1:3050/healthz   # ok
```

Flags fall back to `CODANS_RELAY_LISTEN` and `CODANS_RELAY_DATA`. The relay
speaks plain HTTP/ws; in production Caddy terminates TLS in front of it.
State (registrations and token-hash lists) lives in `<data>/relay.json`.

## Test

```bash
make test          # go vet + go test -race ./...
```

## Deploy

Runs on the nanops VM under systemd, behind Caddy and Cloudflare
(`relay.codans.dev`).

```bash
make deploy        # build linux/amd64, upload to /opt/codans-relay/releases/<sha-ts>/, activate
```

`deploy/activate.sh` installs the systemd unit, points
`/opt/codans-relay/current` at the new release and restarts the service.
The Caddy snippet is installed once by hand:

```bash
scp deploy/codans-relay.caddy root@<vm>:/etc/caddy/conf.d/codans-relay.caddy
ssh root@<vm> 'caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy'
```
