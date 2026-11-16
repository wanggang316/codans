# 0018. The Host zmx daemon starts in the GUI login session when the keychain is locked

Status: Accepted

## Context

An SSH session on a macOS Host cannot read the login keychain. In a remote
Pane, git credential helpers, `gh`, and agent CLIs then have no tokens, and
the agent asks the user to log in again.

## Decision

1. When the keychain is locked for the SSH session, a `zmx` binary is on the
   Host, and a user is logged in at the Host console, the connect script
   starts the Host zmx daemon in the GUI login session with `launchctl submit`.
   The shell of the Pane then has the unlocked keychain.
2. In all other cases the Pane prints a notice that the keychain is locked.
3. A user who wants to keep the boundary of the SSH session does not install
   `zmx` on the Host.

## Consequences

- The Pane reads the keychain items of the user without the login password.
  This is a deliberate reduction of the SSH session boundary. Do not extend it
  to Hosts without a console user or to other operating systems without a new
  decision.
- A keychain item that does not trust the calling binary shows its permission
  dialog on the display of the Host, and the command waits for it.

Current behavior: [Remote Projects](../domains/remote-projects.md#macos-host-and-the-keychain).
