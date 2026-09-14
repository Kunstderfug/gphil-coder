# Publish file-count progress while files finish staging

Type: implementation
Status: open
Triage: ready-for-agent
Parent: PRD umbrella (Kunstderfug/gphil-coder#1)
Depends on: 003

## What to build

On the signed ticket-003 MediaFlow build, File Copy file-count progress
stays at zero for the whole transfer phase while byte progress and speed
update. A live SMB/NAS run showed **0 of 1777**, **0 copied**, and footer
**Copied 0, skipped 0, failed 0 of 1777** together with **8.98 GB copied**,
**16% of bytes**, current file **117.mp4**, and ~80 MB/s. Treat that as
stuck count publication, not "the current file is still open."

The executor is a two-phase transaction: it stages every file into the
destination-volume transaction root (this is the long copy, including
intra-file `copiedBytes` from ticket 002), then creates directories and
installs. `makeProgress` sets `copied` and `completed` from
`MediaCopyResult.copied`, which increments only after each install. Intra-
file and per-file staging publications therefore keep counts at 0 until
the later install phase. Header "N of total", the "N copied" label, and
the status footer all bind that same stale snapshot.

Ticket 003 still requires count-based completion **alongside** the byte
fraction. Keep both. Do not drop the count or replace it with bytes only.

Publish a transfer-finished file count as soon as a file finishes staging
(or is skipped or failed during the transfer phase), and bind the File Copy
count surfaces to that owner:

- header **N of total** advances when files finish transferring;
- the **N copied** label advances for successfully staged files;
- the footer **Copied N, skipped S, failed F of total** uses the same
  snapshot so the three cannot diverge;
- intra-file byte ticks must not increment file counts;
- after the last file finishes staging, publish immediately — do not wait
  for a following file or for install;
- install-phase publications must not reset the displayed counts downward;
- `MediaCopyResult.copied` remains the installed/committed count;
- existing executor tests that treat `progress.copied == 1` as the first
  destination commit must keep meaning "installed," not "staged."

## Current behavior (evidence, not contract)

- Staging publications pass the still-zero `result` into `makeProgress`.
- `completed` is `copied + skippedExisting + failed`; skipped can move
  during staging, but successful transfers do not.
- Byte fraction and window/average speed from ticket 003 work.
- After every file is staged, install increments `result.copied` and only
  then do counts leave 0. On a 1777-file NAS copy that is after the entire
  transfer.

## Ownership

| Behavior/state | Authoritative owner (module) | Platform input/output | Presentation-only state |
| --- | --- | --- | --- |
| Transfer-finished file count during staging | Copy transaction executor via the existing progress channel | Filesystem stage/skip/fail | None |
| Installed/committed copy count | Copy transaction executor (`MediaCopyResult.copied`) | Destination install/rollback | None |
| File Copy count display bindings | Media file coordinator plus EncoderViewModel | None | Header N of total, N copied, footer Copied N |
| Byte progress and speed | Ticket 002 executor stream and ticket 003 sampler (unchanged) | None | Byte totals, percent, current/average MB/s, stalled |

## User actions

None — this reworks status observation of a running copy. Start, Cancel,
Queue, and Copy Now keep their identities.

## Acceptance criteria

- [ ] Executor/coordinator public seam: during a multi-file Copy Now whose
      bytes advance across at least one finished file and into a later
      file (or after the first file has fully staged), published File Copy
      display counts are greater than 0 **before** the later install phase
      would have incremented `MediaCopyResult.copied`. Today this fails —
      header, copied label, and footer stay 0 while `copiedBytes` already
      reflect a completed file.
- [ ] Intra-file ticks do not increment file counts. Count goes from N to
      N+1 only when that file finishes staging, is skipped, or fails.
- [ ] Header "N of total", "N copied", and footer "Copied N, skipped S,
      failed F of total" share one published snapshot and stay consistent
      with each other for the whole run.
- [ ] Install publications do not drop the displayed counts. A successful
      run still ends with count completion matching the planned file total
      (copied + skipped + failed = total) together with byte fraction 1.0.
- [ ] `MediaCopyResult.copied` stays install-committed. Cancellation and
      rollback tests that key off `progress.copied == 1` as first destination
      commit remain valid and still fire after install, not after staging.
- [ ] Ticket 002 intra-file `copiedBytes`, skip-zero bytes, cancel cleanup,
      and package fidelity do not regress. Ticket 003 window/average speed,
      stall, and byte fraction stay visible and do not replace the count.
- [ ] Count ticks mutate only the published progress / copy-status display.
      Queue, plan, and scan identities stay unchanged. Start, Cancel, Queue,
      and Copy Now identities stay unchanged.
- [ ] Focused public-seam tests, existing 002/003 suites green,
      `git diff --check`.
- [ ] Manual signed-build residual: the live 1777-file SMB run needs a new
      signed build from this ticket branch to pick up the fix. The already
      running 003 bundle will keep showing 0 until replaced.

## Blocked by

- 003 — count-based completion alongside byte fraction is specified there;
  this ticket restores the count publication the signed 003 build is
  missing during staging.

## Out of scope

- Ticket 004 (named saved copy-queue library) and last-session queue
  persist (ticket 001).
- Folder Sync copy progress.
- Changing Copy Now / Queue / Cancel identities or transactional stage-
  then-install durability.
