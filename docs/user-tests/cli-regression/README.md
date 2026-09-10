# CLI regression harness

`harness.sh` drives an isolated Debug instance of Codans through every
`codans` verb and asserts exit codes (and, where it matters, output): app
diagnostics, `tree`, project / worktree / tab / pane lifecycle, terminal I/O
(`send`, `send-key`, `read`, `capture`, `broadcast`), in-pane `current`
resolution, agent profiles, and hand-off. It is the runtime check for the
`codans` CLI and the published skill; unit tests cover the handlers in
isolation and cannot see drift between the two.

```bash
make mac-build
APP=$(cd apps/mac && xcodebuild -workspace codans.xcworkspace -scheme Codans \
  -configuration Debug -showBuildSettings 2>/dev/null \
  | awk '$1=="BUILT_PRODUCTS_DIR"{d=$3} $1=="FULL_PRODUCT_NAME"{p=$3} END{print d "/" p}')
bash docs/user-tests/cli-regression/harness.sh "$APP" all
```

## Isolation

- The app is launched from its binary with `CODANS_CONFIG_DIR` set to a
  scratch directory and `CODANS_SOCKET_PATH=/tmp/codans-t-<uid>.sock`; the
  calling pane's own `CODANS_*` / `ZMX_*` / `TERM_PROGRAM` variables are
  unset first, so neither the instance nor the CLI can reach a real app.
- `status` uptime is asserted right after launch; a socket answered by an
  older instance aborts the run.
- Every id comes from the harness's own `project add` / `tab new` /
  `pane new` output.
- Agents are shell scripts named `claude` / `amp` on a private directory,
  reached through agent profiles in the scratch `settings.json` whose
  `envVars.PATH` puts that directory first. `RECEIVED:` on screen proves a
  typed kickoff was submitted.
- `fetchRemoteOnCreate` is off in the scratch settings: the fixture's
  `origin/*` refs have no URL.

## Reading results

`results.tsv` (in the work directory, printed at the end) has one row per
case: id, PASS/FAIL, wanted exit code, got exit code, description, command.
Per-case stdout / stderr are under `logs/<id>.out` / `.err`.

Parser-rejected command lines (unknown option, missing argument) exit 64;
user errors 1; not-found 2; conflict 3; unsupported 4; app unreachable 10;
request timeout 11.

## Traps

- `ctrl_d` ends a shell pane; the key sweep uses a throwaway pane.
- Do not run `xcodebuild test` while the harness is up — it rewrites the
  Debug bundle under the running instance.
- A pane that is not `pane close`d leaves a zmx daemon behind after the
  app quits (`pgrep -f '<Codans.app>.*zmx'`).
