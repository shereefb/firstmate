# Board loop

`bin/fm-board-loop.sh` is the single owner of one board-level
detect -> investigate -> recover -> verify pass over the Operating Studio Linear
board and the workers bound to it.
`docs/scripts.md` lists the command; the script header owns its flags, schemas,
and environment boundaries.
This page owns the design contract and the transition ownership that the
command enforces.

## The transition system

Delivery has one owner per transition, and each transition is independently
verifiable.

| Transition | Owner | Evidence it must record and verify |
| --- | --- | --- |
| Ready to Build -> In Progress | build lane | worker binding and first PR |
| In Progress -> In Review | build lane | canonical PR URL plus exact head, read back from the forge |
| In Review -> Ready to Merge / In Progress | review coordinator | LAND or DO NOT LAND disposition, read back from Linear |
| Ready to Merge -> Ready to Deploy | primary coordinator | one serial landing, read back from the forge and Linear |
| any missed transition | board loop | idempotent repair, read back after every mutation |

The board loop never reviews or merges a pull request. `enforce` may move a card
from In Progress to In Review after it verifies the recorded pull request and
exact head, or from Ready to Merge to Ready to Deploy after the guarded serial
merge has already landed at that exact head. The Linear mutation response must
read back the requested card id and state before the transition succeeds.

## Identity and authority

A lane joins a card only through the immutable Linear issue id recorded as
`linear_card_id=` in task metadata.
A PR is authoritative only through the task's recorded `pr=` URL and
`pr_head=` sha.
Title search is a fallback discovery hint at most: it is never performed by the
board loop and never overrides a canonical binding.
A recorded head that no longer matches the live open-PR head is a real cause,
because no review or landing verdict survives a head change.

## Capacity

Productive capacity is a live, working agent whose disposition is not
terminal/done/parked/paused/blocked, whose validation is not blocked or failed,
and whose card is still active.
A pane, a stale status-log event, a historical activity record, or a lane whose
disposition has not moved across passes is never productive coverage.
A lane that holds the same disposition with no new status bytes or PR head
across the stall window is surfaced as `stalled-disposition` rather than counted
as active indefinitely.

## Decisions and acknowledgements

A decision is not complete when it is recorded or queued.
`fm-send.sh --resolve-key` records the exact decision key, inbox record, and
post-close status offset. The board loop tracks four states: recorded,
delivered (that exact inbox record exists), acknowledged (the worker moved that
record into `handled/`), and consumed (the worker wrote fresh productive status
output or the lane reached a terminal disposition).
An acknowledged but unconsumed decision on an active card is a concrete cause,
retried idempotently after temporary supervisor ownership clears.
A decision delivered but unacknowledged past the ring ladder escalates.

## Throughput health

The command keeps a durable ledger of cards newly verified Ready to Deploy and
counts those inside the rolling prior hour.
Zero landings while eligible work is active is an actionable end-to-end flow
fault, never a healthy idle result.
The fault is surfaced in `throughput.fault` and in
`summary.end_to_end_fault`.

## Recovery boundary and stop posture

`recover` is bounded and untrusted-safe. It steers an owning worker through the
durable inbox (`bin/fm-send.sh`) at most three times per continuous
`(task, reason)` episode, at 15-minute intervals. The retry record clears when
the cause clears, so a later recurrence starts a new bounded episode.
It never issues a lifecycle action, reviews, or merges.

Recovery fails closed while a durable stop posture is active.
The guard is the `state/.board-loop-pause` marker: `fm-board-loop.sh pause`
writes it and `fm-board-loop.sh resume` removes it.
A process override (`FM_BOARD_LOOP_PAUSE=1`) and a configured stop-status file
(`FM_BOARD_LOOP_STOP_STATUS`, whose newest line for a stop key such as
`operating-studio-stop` must not be paused or blocked) are also honored.
While the guard is active, `recover` sends no steer at all; `scan` remains
read-only and may run under the stop posture.
A live endpoint is never evidence that recovery is safe.
The guard is checked again at each steer and each Linear write.

An unavailable Linear, forge, Herdr, or crew-state input is reported as explicit
`unavailable`/`unknown` evidence rather than guessed into a healthy verdict.

## Integration

The command is independent of the read-only Herdr/Linear census in
`bin/fm-herdr-linear-reconcile.sh`.
A home that already has that census passes its inventory to the board loop
through `--remote-inventory` (or `FM_BOARD_LOOP_REMOTE_INVENTORY`), so the
primary never enumerates a second mate's own panes.

The existing Firstmate watcher owns enforcement. A home with a regular
`.env.linear.local` file runs `enforce` on a 15-minute cadence and also runs it
when the watcher wakes for other events. The file supplies
`FM_LINEAR_OPERATING_STUDIO_TEAM_ID`,
`FM_LINEAR_OPERATING_STUDIO_PROJECT_ID`, and a read credential. Direct writes
require `FM_LINEAR_WRITE_API_KEY`. Each home, including the Zues secondmate
home, receives its own local credential configuration; no secret belongs in the
repository. Missing read, write, forge, crew-state, or remote-inventory inputs
appear as source failures and cannot count as healthy capacity or a verified
landing.

Scheduled enforcement never calls `recover` and never sends an inbox steer.
`recover` remains an explicit operator action and still refuses every send while
the durable stop posture is active.
