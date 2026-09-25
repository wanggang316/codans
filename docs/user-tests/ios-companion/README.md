# iOS companion end-to-end harness

`harness.sh` checks the iOS companion against a real Mac gateway. It starts
an isolated Debug instance of Codans with Remote Access turned on. It then
issues pairing codes from that instance's Settings › Remote Access pane,
pressing the buttons through the accessibility API
(`docs/user-tests/_shared/ax/ax.swift`). Finally it runs the `CodansMobile`
UI test (`apps/ios/CodansMobileUITests`) on a simulator.

| Case | What it proves |
|---|---|
| interactive | A "View and type" code opened as a `codans-pair:` link is confirmed, then pairs over Bonjour + TLS-PSK. The fixture project and its pane are listed. A line typed on the phone runs in the Mac pane, and the Mac reads the output back. |
| read-only | A "View only" pairing never shows the input bar. |
| composer | A "View and type" pairing opens the composer at the bottom of the home screen, picks Create New Worktree, and sends a message. The Mac creates the worktree on `agent/<first words of the message>` and starts the fake `claude` profile with the message as its prompt. The phone navigates to the new agent's pane. |
| revoke | Revoking every device in Settings removes their records and their Keychain keys. |

The UI test skips itself unless the harness passes a pairing code through a
`TEST_RUNNER_CODANS_E2E_*` variable, so `make ios-test` never needs a Mac.

## Run

```bash
make mac-build          # Debug Codans.app + CLI
make ios-generate
docs/user-tests/ios-companion/harness.sh \
  ~/Library/Developer/Xcode/DerivedData/codans-*/Build/Products/Debug/Codans.app
```

An optional second argument picks the simulator UDID; it must be on an
iOS 26 runtime. The default is the iPhone 17 Pro on iOS 26.

The terminal running the harness needs Accessibility permission. The
harness borrows the clipboard to copy the pairing code, then restores it.

## Isolation

- The instance gets a private config dir, zmx cache, socket and worktrees
  directory. It never touches the default dev or release instance. Its only
  agent profile runs a fake `claude` that prints its arguments, so no real
  agent session starts.
- The socket and the cache are short `/tmp` paths. zmx puts one socket per
  pane in the cache dir, and AF_UNIX paths are capped near 104 bytes. A long
  cache path makes every pane exit at spawn.
- Pairing keys go into the login Keychain under
  `com.gumpw.codans.remote.codans-dev`, the same service the dev app uses.
  On exit the harness deletes the keys of every device it paired and no
  others.
- Before each case the simulator app is uninstalled and the simulator is
  rebooted. This clears the previous pairing. It also clears any leftover
  SpringBoard "Open in Codans?" prompt, which would otherwise answer the
  next link with a stale code.

## Known gap

When the Mac rejects a pairing (revoked or expired), the phone only sees a
handshake timeout. It shows "Your Mac did not answer in time" and keeps
retrying, instead of asking the user to pair again. The harness does not
cover this path.
