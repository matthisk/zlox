---
name: land
description: >-
  Land ZLox changes into the local source checkout's main branch without
  publishing to GitHub. Invoke only when the user explicitly requests landing
  or merging changes, including /land, not for review, preparation, passing
  checks, or skill installation.
disable-model-invocation: true
metadata:
  delta-action: land
---

# Land ZLox locally

An explicit invocation authorizes completing this workflow, including updating
the source checkout below. Do not ask again for routine merge permission.
Stop for genuine blockers, ambiguous scope, or unsafe changes.

## Destination and scope

- Apply only to the ZLox repository. The destination is `main` in
  `~/dev/github.com/matthisk/zlox`; the workspace's `local` remote must resolve
  to that repository (currently its `.git` directory). Verify both identities
  before proceeding. Never substitute `origin`, contact GitHub, or publish.
- Read applicable repository instructions and inspect the workspace status,
  staged and unstaged diffs, untracked files, branch, and recent history.
  Identify the requested change and any already prepared commits.
  Preserve unrelated work; do not stage everything indiscriminately, stash
  unrelated changes, or discard files. Ask if scope cannot be determined.
- Inspect the destination read-only first. Require it to have `main` checked
  out, a clean index and working tree including untracked files, and no
  operation in progress. Stop rather than switch its branch or clean it.
- Inspect applicable local hooks and contribution requirements. Honor any
  required reviews, signing, or other checks; do not bypass them. Preserve
  configured commit signing. Authentication or signing failures are blockers.
  There were no repository CI workflows or enforced remote checks at setup;
  this is a local-only workflow, not a GitHub merge.

## Prepare the landing commit

1. Fetch `main` from `local` in the workspace and record its exact tip.
   Read the destination tip directly as well and confirm they agree.
   Perform all integration and conflict resolution in the workspace, not
   the destination checkout.
2. If the workspace is on `main`, create a uniquely named temporary landing
   branch before committing. Otherwise use the current branch if its scope
   is appropriate. Do not overwrite an existing branch.
3. Stage only the requested files or hunks and create a focused commit if
   needed. Follow `AGENTS.md`: use a short imperative sentence-case subject
   and explain non-obvious VM or bytecode choices in the body. Use explicit
   `-m` messages and `GIT_EDITOR=true` for Git commands that might open an
   editor. Do not disable signing to make a commit succeed.
4. Compare the candidate against the recorded destination tip. Ensure every
   commit and change that would land belongs to the request. Keep history
   linear: if the destination is not an ancestor of the candidate, rebase the
   landing branch onto the recorded tip with `GIT_EDITOR=true git rebase
   <recorded-tip>`, not a merge. If this would rewrite shared commits, create
   a uniquely named temporary landing branch first and rebase that instead.
   Do not rewrite destination history or update shared branches by force.
   Before verification, require `git rev-list --merges <recorded-tip>..HEAD`
   to produce no output. If the candidate already contains merge commits,
   rebase its requested commits onto the recorded tip on a temporary landing
   branch without `--rebase-merges`, then inspect the resulting diff to ensure
   the intended changes, including conflict resolutions, are preserved.
5. Resolve conflicts automatically when the intended result is clear,
   preserving unrelated work. For ambiguous conflicts, stop and describe the
   conflict for the user; do not guess. Never force-push, reset the destination,
   or bypass failed checks.

## Verify the final candidate

Run from the workspace root on the final integrated candidate:

- `zig build test` — `build.zig` defines `test` using `addTest` on
  `src/main.zig` and a run-artifact dependency.
- `zig fmt --check src build.zig build.zig.zon` — required by `AGENTS.md`;
  these paths are the source directory and build files defined by the project.
  Zig's `fmt --help` supports recursive directories and `--check`.
- `zig build` — `build.zig` installs the `zlox` executable as the default
  build step.

Use the project's Nix-provided toolchain. `.envrc` uses the flake and
`flake.nix` defines a default development shell containing Zig. If that
environment is not active, use `nix develop --command` followed by each exact
command above, from this repository. Do not silently substitute an incompatible
Zig version based on the stale version prose in `CLAUDE.md` or the package's
minimum version alone.

All required checks must have passed for the exact candidate being landed.
Pending, failing, missing, or unverifiable required checks block landing.
After integration, conflict resolution, or any candidate modification, rerun
the checks. Do not assume the test target discovers every Zig test: report
the actual check performed and any relevant discovery limitations.

Apply the contribution conditions in `AGENTS.md`: language behavior changes
need a numbered sample and matching engine test, including relevant success
and compile/runtime failure cases. If a required artifact is missing, stop
and report it rather than silently broadening the landing change. PR text
requirements apply only if a PR is actually requested; this workflow creates
no PR. For documentation-only or skill-only changes, still run the explicitly
required test and format checks above.

## Update and verify the source checkout

1. Record the verified candidate commit ID and ensure no unexpected workspace
   edits appeared during validation.
2. Immediately recheck the destination branch, cleanliness, and tip. If its
   tip advanced, fetch again, repeat the linear-history preparation against
   the new tip in the workspace, and repeat verification. If it became dirty
   or changed branches, stop.
3. Transfer the verified candidate to the destination object database by
   fetching its exact commit from the workspace repository. This is a local
   fetch, not publication. Do not update destination `main` through a push
   or configure `receive.denyCurrentBranch`.
4. In `~/dev/github.com/matthisk/zlox`, with `main` still checked out and clean,
   run `GIT_EDITOR=true git merge --ff-only <verified-commit>` using the actual
   verified commit ID. This source-checkout update is part of the explicitly
   requested landing operation. If fast-forward fails, stop and inspect;
   never replace it with a forced update.
5. Verify the destination's `HEAD` and `main` equal the verified candidate,
   and its index and working tree are clean. Check the destination commit's
   relevant diff to confirm the requested change is included. Leave unrelated
   branches, files, configuration, and `origin` untouched.
6. Report the destination, commit ID, actual checks and results, and that no
   GitHub push occurred. Creating a commit or fetching it is not landing.
   If any blocker prevents completion, explicitly state that the changes
   have not landed. If the merge succeeded but subsequent verification
   failed, state that the destination was updated and describe the unresolved
   verification failure; do not claim either a clean success or no mutation.
