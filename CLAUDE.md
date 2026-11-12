# Claude Tracker: agent rules

## No duplicates without permission

Never create a duplicate of this project without asking the owner first. That covers git worktrees, copied folders, cloned repos, and "-copy" or "-pr" style directories. Work in this folder and use branches. If a second working copy is truly needed, ask, say why, and delete it once its branch is merged.

## Never update the installed app

Do not run `./install.sh`, `./build.sh` into `/Applications`, or use the app's Check for Updates, and do not restart the installed app, unless the owner asks in that message. The owner tests the update path themselves to make sure it updates correctly. Run `./test.sh` and build test copies into a scratch folder instead.

Pushing to `origin` and making GitHub releases is allowed (the owner said so on 2026-11-09). Releases follow the pattern of the earlier ones: bump `Version.swift` and the README's current version, push `master`, tag `vX.Y.Z`, then `gh release create` with notes (New, Fixed, Updating). Push only to `origin`, never to `upstream`.
