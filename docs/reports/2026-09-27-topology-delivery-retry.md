# SAF-09 increment: retain unconfirmed topology delivery

Baseline: 92a46c4 plus accompanying changes. This is a partial implementation,
not completion of SAF-09 or a distributed fencing guarantee.

The previous transport discarded asynchronous send errors, never read flared's
node-sync response, and unconditionally cleared pendingBroadcast after an
attempt. A rejected or unreachable recipient could remain on an older map
until another topology change occurred.

The transport now propagates send failures and requires a complete `OK\r\n`
response within a single three-second receive budget (fragmentation allowed,
bounded response size). EOF, rejection, malformed reply and timeout are failures.
The broadcaster distinguishes a failed Pod list from an empty list; a nonempty
map with no targets is unconfirmed. Its task wait budget is shared across all
targets rather than being fifteen seconds per target. Failed/unconfirmed
attempts preserve the earliest pending version. The next pass sends the latest
committed map through the same pre-send lease fence. Successful responses from
every listed target clear pending delivery. Logs distinguish attempts from
confirmation; no claim is made before receiving the reply.

Nine pure checks pin reply parsing and pending-state transitions (154 unit
checks total). The selective read-guard E2E now sets desired balance zero
before healing, requires an unconfirmed-delivery log, and requires recovery
without the previous forced 50-to-0 topology transition. Other live changes
can still advance the map, so this is not isolation of same-version retry as
the sole recovery cause. Runtime acceptance is pending CI.

Residuals: no persistent per-Pod-UID applied-generation ledger, no recovery
guarantee after process restart or an unobserved recipient restart, no repair
of leader-generation regression, and no closure of the check/send lease race.
Only pods returned by the API with usable addresses are targeted. One failed
target causes the whole current map to be resent next pass; no unbounded queue
of old maps is kept. Shutdown and timed-out tasks remain best-effort. A reply
confirms processing at that time, not future data health or lasting authority.
