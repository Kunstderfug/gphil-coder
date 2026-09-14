# Save named copy queues and load them as workflows

Type: implementation
Status: open
Triage: ready-for-agent
Parent: PRD umbrella (Kunstderfug/gphil-coder#1)
Depends on: None

## What to build

Users can save the current File Copy **queue** under a chosen name and later
load that named save so the queue is restored as the same **workflows** they
can run again.

This is not ticket 001. Ticket 001 already auto-persists the last in-memory
queue across relaunch (`MediaCopyQueueStore` writing one
`MediaCopyJobDocument`). This ticket adds a **named library** of saved queues
so a user can keep several reusable copy setups, pick one by name, and load
it without hunting for a Finder `.job` file.

Existing File Copy vocabulary stays in force:

- The in-memory queue is an ordered array of `MediaCopyWorkflow` values
  (source roots, destination root, destination layout, filter, selected
  extensions, filename filter, stable workflow `id`).
- **Add to Queue** still appends one workflow built from the current copy
  form.
- **Copy Now**, **Run**, **Clear**, **Remove**, **Repair**, and the Finder
  **Load** / **Save** Job (`.job`) entry points keep their identities.
- Loading a named save uses the existing queue-replace path
  (`replaceMediaCopyQueue` / `loadMediaCopyJobData` semantics): the loaded
  workflows become the working queue. It does not invent a second queue
  owner and does not auto-run.

The closest product analog is encoding presets: a named, in-app, durable
list with save / load / overwrite-same-name / delete. Reuse
`MediaCopyWorkflow` payload semantics and the versioned job-document
workflow shape; do not invent a second copy-item schema.

## Current behavior (evidence, not contract)

- The working queue is owned in memory by `MediaFileCoordinator` and
  auto-persisted by `MediaCopyQueueStore` as the last-session document.
- Finder **Save** / **Load** already round-trip the whole queue as a `.job`
  `MediaCopyJobDocument`. That path stays. It is not a named in-app library.
- Encoding already has named reusable presets (save / load / update /
  rename / delete). File Copy has no equivalent named library.
- Ticket 001 must not be reimplemented as "named saved workflows."

## Ownership

| Behavior/state | Authoritative owner (module) | Platform input/output | Presentation-only state |
| --- | --- | --- | --- |
| Named saved-queue library document (versioned, atomic) | New saved-workflow library module in the app target | Application Support file read/write, corrupt-file quarantine | Picker selection |
| Working in-memory queue, repair issues, busy guard | `MediaFileCoordinator` (existing) | Folder existence checks | Queue rows, NEEDS REPAIR badges |
| Save / load / delete named library commands | `EncoderViewModel+MediaCopyActions` entry points the Copy Queue UI already uses for job save/load | Injectable name prompt and delete confirmation (default AppKit alerts) | Status message |
| Last-session queue persist | `MediaCopyQueueStore` (ticket 001, unchanged) | Existing Application Support queue document | None |

## User actions

- **Save as Workflow** (Copy Queue): prompt for a trimmed non-empty name;
  persist the current working queue as a named library item. If a library
  item already has that name (case-sensitive after trim), overwrite that
  item's workflows and keep its stable library identity. Disabled when the
  queue is empty or a file-management copy is busy.
- **Load Workflow**: replace the working queue with the selected named
  item's workflows through the existing replace-queue path. Missing folders
  still surface NEEDS REPAIR and cannot run until relinked. Disabled when
  nothing is selected or a copy is busy.
- **Delete Workflow**: confirm, then remove the selected named item from
  the library. Does not clear the working queue unless the user later
  loads a different item or clears the queue themselves.
- Finder **Load** / **Save** Job, **Copy Now**, **Add to Queue**, **Run**,
  **Clear**, **Remove**, and **Repair** keep their identities.

## Acceptance criteria

- [ ] Library seam: saving the current queue under a name persists a
      library item whose workflows (IDs, order, source sets, destination
      root and layout, filter, extension and filename filters) a freshly
      composed model reloads identically. Fails red today — no named
      library exists.
- [ ] Load-as-workflow seam: loading a named item replaces the working
      queue through the existing replace-queue path; the loaded workflows
      are runnable when folders exist, and NEEDS REPAIR when they do not.
      Load never starts a copy.
- [ ] Name overwrite: saving again with the same trimmed name updates that
      item in place (same library id) rather than creating a duplicate
      name. A different name adds a new item. Empty or whitespace-only
      names are rejected and do not write.
- [ ] Delete persist: deleting a named item removes it from a freshly
      composed model's library; the working queue is unchanged by delete
      itself.
- [ ] Last-session persist stays separate: loading a named item updates
      the working queue, so ticket 001's existing `didSet` persist still
      writes the last-session document. The named library file is a
      different document and is not the last-session queue file.
- [ ] Finder Save/Load Job identities unchanged: `.job` panels and
      `MediaCopyJobDocument` version 1–2 contract stay as they are.
- [ ] Corruption gate: a corrupt or future-version library document
      yields an empty library, a repairable status message, and the
      original bytes preserved (quarantined). A failed decode never
      replaces the working queue.
- [ ] Tests never touch the live Application Support library or queue
      directories. Existing coordinator and queue-persist suites keep
      using injected temporary directories, including the new library
      root.
- [ ] Focused composition-root suite green, existing copy suites still
      green, `git diff --check`.
- [ ] Manual smoke: queue one or more copy workflows, save under a name,
      clear or change the queue, load the named item, and confirm the
      workflows return and can run. Repeat overwrite-same-name and delete.

## Blocked by

- None — independent of tickets 002 and 003 (copy progress / speed).
  Base from current `main`. Do not merge 002/003 into this branch.

## Out of scope

- Auto-persist last queue (already ticket 001).
- Renaming a library item without overwrite-by-same-name (not requested).
- Encoding-queue `.gphilcoderqueue` files or Folder Sync pair lists.
- Changing Copy Now into a saved-workflow runner.
- New document version for `MediaCopyJobDocument`.
