# Show network-aware copy speed and byte-based progress

Type: implementation
Status: open
Triage: ready-for-agent
Parent: PRD umbrella (Kunstderfug/gphil-coder#1)
Depends on: 002

## What to build

The displayed copy speed is a cumulative average since the transaction
started (`total bytes copied / total elapsed time`). On network drives this
is misleading: an early cache-flush burst inflates it, a mid-run SMB/NAS
stall drags it down for the rest of the run, and it never shows the current
link throughput. The elapsed denominator also covers per-file evidence
capture and install bookkeeping, so with many small files the number sits far
below real link capability; and the completion percentage is count-based, so
the bar jumps file-to-file instead of tracking bytes.

Show speed the way a user judges a network copy:

- **Current speed** derived from a sliding window of recent byte progress
  (for example the last 10 seconds), computed by a pure, clock-injectable
  sampler in the core module — not from wall-time averages inside the view;
- **Average speed** over the whole run, kept alongside the window value;
- **Stalled state**: when bytes stop arriving for a sustained interval while
  a file is actively transferring, show an explicit stalled indication
  instead of a frozen number; it clears when bytes resume. Brief inter-file
  bookkeeping (evidence capture, directory creation) must not be flagged as
  a stall — the stall threshold must be well above normal per-file gaps, or
  stall detection must only apply while a file transfer is in flight;
- **Byte-based progress fraction** (`copiedBytes / totalBytes`) shown with
  the count-based completion, so heterogeneous file sizes no longer make the
  bar jump; the run completes at 100% exactly when bytes complete;
- Before the first bytes land, keep the existing "Calculating speed" state,
  which with byte-level progress (002) now lasts moments rather than a whole
  first file;
- Keep decimal MB/s formatting and label it consistently.

The sampler must not silently count skipped-existing files as throughput, and
window samples must age out so old bursts cannot mask a current stall.

## Current behavior (evidence, not contract)

- Speed is a single cumulative-average computed property; no window, no
  stall state, no sample history.
- Progress fraction is count-based; byte totals exist but do not drive the
  bar.

## Ownership

| Behavior/state | Authoritative owner (module) | Platform input/output | Presentation-only state |
| --- | --- | --- | --- |
| Speed samples, window/average math, stall detection | Pure speed sampler in the core module (injected clock) | Consumes published byte-progress snapshots | None |
| Derived display values (current/average speed, stalled flag, byte fraction) | Media file coordinator binding | None | Speed text, stalled indicator, byte-progress bar |
| Copy execution and byte progress publication | Copy transaction executor (ticket 002) | Filesystem transfer | None |

## User actions

None — this reworks status presentation of a running copy. All copy entry
points keep their identities.

## Acceptance criteria

- [ ] Sampler seam (core unit tests, injected clock): steady-rate samples
      produce a window speed matching the rate regardless of earlier ramp
      history; a burst followed by a stall decays the window speed toward
      zero while the average stays; samples older than the window are
      dropped. Fails red today — no sampler exists.
- [ ] Stall seam: a sustained no-byte interval during an active transfer
      raises the stalled state; resuming bytes clears it; normal inter-file
      bookkeeping gaps of the same run never raise it.
- [ ] Coordinator seam: during a synthetic slow copy, published display
      state carries the window speed (not the cumulative average) and a byte
      fraction that reaches exactly 100% when the run completes.
- [ ] Display seam: the copy status area shows current and average speed,
      the stalled indication appears and clears per the sampler, and the
      byte-based fraction is visible alongside count completion; MB/s labels
      are consistent.
- [ ] Invalidation budget: speed text and indicators update at the bounded
      cadence of the underlying progress publications; speed ticks do not
      invalidate queue, plan, or scan state.
- [ ] Skips never count as throughput in either window or average.
- [ ] Focused sampler, coordinator, and display tests, `git diff --check`.
- [ ] Manual signed-build smoke: copy to an SMB/NAS share, pull the network
      mid-copy; the window speed falls toward zero and the stalled state
      appears; restore the network; speed recovers without restarting the
      app. Note qualitatively whether the reported number now tracks the
      link.

## Blocked by

- 002 — byte-level copy progress provides the sample stream this ticket
  consumes.
