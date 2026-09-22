# Board loop

`bin/fm-board-loop.sh` is the single owner of one board-level
detect -> investigate -> recover -> verify pass over the Operating Studio Linear
board and the workers bound to it.
`docs/scripts.md` lists the command; the script header owns its flags, schemas,
and environment boundaries.
This page owns the design contract and the transition ownership that the command observes.

## The transition system

Delivery has one owner per transition, and each transition is independently
verifiable.

| Transition | Owner | Evidence it must record and verify |
| --- | --- | --- |
| Ready to Build -> In Progress | build lane | worker binding and first PR |
| In Progress -> In Review | build lane | canonical PR URL plus exact head, read back from the forge |
| In Review -> Ready to Merge / In Progress | review coordinator | LAND or DO NOT LAND disposition, read back from Linear |
| Ready to Merge -> Ready to Deploy | primary coordinator | one serial landing, read back from the forge and Linear |
| any missed transition | existing watcher and owning coordinator | route the cause to its owner, then verify a fresh readback |

The board loop never mutates Linear, reviews a pull request, merges a pull request, or creates a second scheduler.
The existing watcher runs the detector and wakes the coordinator that already owns the required build, independent-review, or guarded serial-merge transition.
The next detector pass supplies the readback.

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

The command keeps a permanent identity ledger of exact-head landings and counts authoritative forge merge times inside the rolling prior hour.
Zero landings while eligible work is active is an actionable end-to-end flow
fault, never a healthy idle result.
The fault is surfaced in `throughput.fault` and in
`summary.end_to_end_fault`.

## Recovery boundary and stop posture

`recover` is bounded and untrusted-safe.
It steers an owning worker through the durable inbox (`bin/fm-send.sh`) at most three times per continuous `(task, reason)` episode, at 15-minute intervals.
The retry record clears when the cause clears, so a later recurrence starts a new bounded episode.
It never issues a lifecycle action, reviews, or merges.

Recovery fails closed by default.
`fm-board-loop.sh resume --card <Linear-id-or-identifier>` writes one durable card grant, while `pause` revokes every grant.
The process override `FM_BOARD_LOOP_PAUSE=1` refuses every recovery.
Status history and endpoint liveness never create or clear a grant.
`scan` remains read-only under every stop posture.
A live endpoint is never evidence that recovery is safe.
The card grant is checked again at each steer.

An unavailable Linear, forge, Herdr, or crew-state input is reported as explicit
`unavailable`/`unknown` evidence rather than guessed into a healthy verdict.

## Integration

Each home exports its own `inventory` with its owner identity and observation time.
An importing home accepts only fresh, valid inventories passed through `--remote-inventory` or `FM_BOARD_LOOP_REMOTE_INVENTORY`.
Remote recovery routes to the owning secondmate task, never to the remote child id through the wrong home.

The existing Firstmate watcher runs `scan` on its 15-minute cadence when the board-owner home has `.env.linear.local`.
The file supplies `FM_LINEAR_OPERATING_STUDIO_TEAM_ID`, `FM_LINEAR_OPERATING_STUDIO_PROJECT_ID`, and a read credential.
Zues receives routed causes through the existing owner cycle and needs no copied Linear secret or separate writer.
Missing Linear, forge, crew-state, or configured remote-inventory inputs appear as source failures and cannot count as healthy capacity or a verified landing.

The scheduled detector never calls `recover` and never sends an inbox steer.
An unchanged actionable cause wakes supervision again at the bounded alert cadence until readback clears it.
