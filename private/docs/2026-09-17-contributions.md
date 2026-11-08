# Contribution review — September 17, 2026

No evidence of malicious additions was found in the revisions reviewed below.
This is a review of specific code, not a guarantee about contributors, future
commits, or the absence of every vulnerability.

## Scope

| Contribution | Revision | Status at review |
| --- | --- | --- |
| [PR #2](https://github.com/rileycx/strafe/pull/2), Ozair Khan | `fe85fd979a9df8728a27d5c52e3fbcb29ff38f23` | Full PR remains unmerged; only the Mission Control detection check is adopted |
| [PR #4](https://github.com/rileycx/strafe/pull/4), Maroun Najjar | `0d23329f98c8cc9a3d1e46b71120fd06714d405b` | Unmerged |
| [PR #5](https://github.com/rileycx/strafe/pull/5), Matteo Sandrin | Original `dce2c44039ba0dc19584931ce0060eb152b9b705`; fixed merge `2ee2c9635477db4e71b0fdff6059b6f321a51729` | Merged with launch visibility fix |

The review covered the complete contribution diffs, added runtime code, tests,
scripts, documentation, and file modes. Text scans supplemented manual reading
for networking, subprocess execution, dynamic loading, credential and clipboard
access, screenshot capture, encoded payloads, and hidden control characters.

## Security observations

- No added network requests, credential access, clipboard reads, screenshot
  capture, subprocess execution in the app, or downloaded executable code were
  found. The binary event payloads in PR #2 construct synthetic gestures in
  memory; they are not executable payloads.
- None of these PRs changes GitHub workflows, workflow permissions, package
  dependencies, entitlements, or installation scripts. No binary artifacts,
  symlinks, or submodules are added. PR #2's bundle-script addition copies local
  license text into the bundle; its test script builds and runs local tests.
- PR #2 expands the event mask to include fluid-touch gesture type 31. It still
  excludes key-down and key-up events. It adds a Dock Accessibility observer
  for overlay notifications, using the existing permission. Its optional
  diagnostics print gesture metadata and display/Space identifiers to stderr;
  errors are also printed without diagnostic mode. These are additional
  observable data, and are not part of the small fix adopted here.
- PR #4 persists the hotkey setting and registers/unregisters the existing
  Carbon shortcuts. It adds no broad keyboard event tap. Its CLI writes only
  the stored setting: an already-running app does not apply that write, and
  its menu can show a setting that differs from the active registrations.
  This correctness issue remains to be fixed before merging it.
- PR #5 hides the icon only after a confirmation and restores it on reopen.
  The merged fix restores visibility on fresh launch, too. AppKit persists
  status-item visibility automatically; the README and security notes account
  for that storage. No new background service or launch persistence is added.
- PR #2 also retains the previously identified overlay-state and 100 ms
  settling-delay concerns. This review does not approve its full engine rewrite.

## Adopted change and validation

The adopted check comes from Ozair's
[Mission Control commit](https://github.com/Ozdotdotdot/strafe/commit/2b75106ff9c17c832f51065f1c64f25c98f9acbf).
It recognizes a Dock-owned layer-20 window without requiring a layer-18 window.
The adaptation limits this behavior to macOS 27 and later, preserving the
existing rule on earlier systems. It reads the same window metadata as before
and changes no input mask, permissions, logging, or gesture synthesis.

On macOS 27.0 (26A428), an isolated probe confirmed:

| Desktop state | Dock layer 18 | Dock layer 20 | Before | After |
| --- | --- | --- | --- | --- |
| Normal desktop | 0 | 0 | Inactive | Inactive |
| Mission Control open | 0 | 1 | Inactive | Active |
| Mission Control closed | 0 | 0 | Inactive | Inactive |

The added C regression failed before the fix and passed afterward. Fixtures
cover unavailable/empty window lists, legacy overlay layouts, unrelated window
owners and layers, and the macOS 27 layout. The Swift regression checks that an
overlay swipe passes through unchanged without requesting a replacement switch.
The existing Space-boundary regressions still pass.

Strict Swift compilation, the four Swift tests, C tests with undefined-behavior
sanitization, release bundling, and signature verification passed locally.
Earlier macOS releases were not runtime-tested. These checks do not constitute
a comprehensive penetration test or a certification of the whole application.

## PR #4 follow-up

The hotkey toggle was updated to notify running copies after a preference write
and to preserve registration handles across repeated enable requests. The
original contribution remains authored by Maroun Najjar; the integration and
follow-up changes are maintainer commits.

The added `DistributedNotificationCenter` notification stays in the same login
session and carries no payload. The receiver ignores notification data, reloads
its own saved preference, and only updates the existing Carbon registrations.
Observers are removed on shutdown. No network, subprocess, credential access,
additional input mask, or permissions were added to the app.

The new test script compiles the production manager with an isolated preference
domain and replacement Carbon registration functions. Tests cover default-on
behavior, repeated enable/disable, stop/start, and live updates from a separate
process without taking over real keyboard shortcuts. These tests, the existing
Swift and C tests, strict compilation, bundling, and signature verification all
passed locally. CI now runs the same hotkey tests with its existing read-only
permissions and without introducing dependencies or secrets.
