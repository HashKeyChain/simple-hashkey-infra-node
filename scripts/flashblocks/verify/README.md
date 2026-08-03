# Flashblocks Verification Scripts

These scripts make Flashblocks acceptance checks repeatable. Each script covers one
category and reports `PASS / FAIL / WARN / SKIP`. Exit code 0 means every required check
passed, making the scripts suitable for CI and repeated local verification.

Gate definitions are in section 7 of `doc/flashblocks_local_impl.md`; operational
procedures are in `doc/chain-lifecycle.md`.

## Quick Start

```bash
# Select verification gates automatically from the chain's current state.
bash scripts/flashblocks/verify/run-all.sh

# Run a quick pass without sending transactions.
bash scripts/flashblocks/verify/run-all.sh --quick
```

## Usage

Run commands from the repository root. The scripts load `.envrc` automatically and read
the current chain using its ports and `DEPLOYMENT_CONTEXT`; manually running
`source .envrc` first is unnecessary.

### 1. off / Before Initial Integration

```bash
# Check binaries, versions, genesis, slicing parameters, and JWT.
bash scripts/flashblocks/verify/p0-genesis.sh

# After op-rbuilder shadow synchronization, check chain heads, sampled block hashes,
# and continued synchronization.
bash scripts/flashblocks/verify/p1-shadow.sh --lag=2 --samples=10 --watch=30
```

When integrating Flashblocks from off mode for the first time, first run
`scripts/flashblocks/switch-to-flashblocks-dryrun.sh` to catch up op-rbuilder and transfer
Engine control. Do not start directly in enabled mode with an empty data directory.

### 2. dry_run Verification

```bash
# Run P0 + P1 + P2 automatically.
bash scripts/flashblocks/verify/run-all.sh --watch=300

# Run only the core dry_run gate.
bash scripts/flashblocks/verify/p2-dryrun.sh --watch=300
```

Before switching to enabled, confirm at least the following:

- `p2-dryrun.sh` reports no FAIL;
- `InvalidPayload = 0` and no `Payload ID mismatch` exists;
- the builder has enough candidate-block delivery samples, preferably at least a 95%
  delivery rate;
- the chain continues producing blocks at the expected rate;
- `context=builder = 0` in dry_run, meaning no builder candidate was adopted on-chain.

Additional mismatch check (normally produces no output):

```bash
rg -ni 'InvalidPayload|Payload ID mismatch|payload.*mismatch' data/logs/rollup-boost.log
```

Run dry_run before the initial launch on both testnet and mainnet.

### 3. enabled Verification

```bash
# Already enabled: check builder-block adoption, block production, Flashblock
# production, and WebSocket broadcast.
bash scripts/flashblocks/verify/p3-enabled.sh --watch=300

# Switch live from dry_run to enabled. Remain enabled and update .envrc on success;
# restore the original mode on failure.
bash scripts/flashblocks/verify/p3-enabled.sh --switch --watch=300

# Alternatively, run P0 + P1 + P3 + P4 automatically for the current mode.
bash scripts/flashblocks/verify/run-all.sh --watch=300
```

`p3-enabled.sh` prints each WebSocket message's block number, `index`, and byte count,
then summarizes the number of Flashblock slices received for each block in the
observation window.

Do not use `--fallback-drill` for routine acceptance testing. It switches rollup-boost
to disabled and may disconnect op-rbuilder permanently from the chain. The default
fallback check only reads existing logs and does not induce a failure.

### 4. User-Facing Verification

P3 verifies the builder and WebSocket stream. P4 performs only the basic user-facing check:
submit transactions through op-reth, observe each one in its `pending` view before the
canonical RPC (`L2_RPC`) sees the receipt, and require that observation to happen in under
one second.

```bash
# Check the RPC and send three sample transactions.
bash scripts/flashblocks/verify/p4-user-facing.sh

# Check only whether the RPC is reachable.
bash scripts/flashblocks/verify/p4-user-facing.sh --samples=0
```

Sampling uses `DEPLOY_PRIVATE_KEY`. Use only a disposable funded test key; `cast` passes it
on the command line while signing.

### 5. Local Acceptance

```bash
# Gates P0/P1/P3/P4, end-to-end scenarios, fault-proof non-regression, plus a report.
bash scripts/flashblocks/verify/p5-acceptance.sh --watch=60

# Rerun only the P5-specific scenarios after the gates already passed.
bash scripts/flashblocks/verify/p5-acceptance.sh --skip-gates
```

The report lands in `data/verify-reports/p5-<timestamp>.md`; use `--report=PATH` to place it
elsewhere. The scenarios are a plain transfer, a contract deployment plus call, and a
reverting transaction, all submitted through op-reth, each cross-checked so op-reth and
op-geth agree on the block it landed in.

Both drills are destructive and off by default. `--fallback-drill` forwards to the p3
drill. `--restart-off-drill` stops the chain, restarts it in off mode, verifies it, and then
switches back to enabled; it takes at least ten minutes and is bounded by the
`channel_timeout` restart window, so it asks for confirmation unless `--yes` is given.

Out of scope for P5: deposits and withdrawals, CGT gas accounting (see
`scripts/jovian/verify-jovian-fees.sh`), and L1 origin rotation.

### 6. Results and Exit Codes

- `PASS`: the check passed;
- `FAIL`: a hard gate failed, and the script ultimately returns a nonzero exit code;
- `WARN`: a risk or suboptimal metric exists but does not independently fail the run;
- `SKIP`: prerequisites or samples are insufficient, so the item is not verified.

CI and release scripts can rely directly on the exit code:

```bash
if bash scripts/flashblocks/verify/run-all.sh --watch=300; then
  echo "Flashblocks verification passed"
else
  echo "Flashblocks verification failed"
  exit 1
fi
```

## Script Responsibilities

| Script | Verification | Prerequisites |
|---|---|---|
| `p0-genesis.sh` | All four Rust binaries are available, versions are pinned to Jovian, fork times are embedded in genesis, op-rbuilder and op-geth genesis hashes match, per-block slice count is configured correctly, and all components share one JWT | None; genesis comparison requires both nodes to run, otherwise it is skipped |
| `p1-shadow.sh` | op-rbuilder catches up to the chain head, sampled block hashes exactly match op-geth, no invalid blocks exist, and both sides advance together | op-geth + op-rbuilder running |
| `p2-dryrun.sh` | Six checks: dry_run mode -> op-node uses rollup-boost -> builder op-node is stopped -> block production is unaffected -> **no builder block is marked INVALID** -> builder delivers candidate blocks | `dry_run` mode |
| `p3-enabled.sh` | Builder blocks are used for the canonical chain, Flashblocks are produced continuously, the external broadcast (:1112) completes a handshake and carries data, and builder failures fall back automatically to op-geth | `enabled` mode, or add `--switch` |
| `p4-user-facing.sh` | op-reth and canonical RPCs are reachable, and **transactions are visible in pending under a second, before the canonical RPC sees their receipts** | both RPCs running; sampling needs a funded test key |
| `p5-acceptance.sh` | Runs P0/P1/P3/P4, then end-to-end scenarios (transfer, contract deployment and call, reverting transaction) and fault-proof non-regression, and writes a Markdown report | `enabled` mode; scenarios need a funded test key |
| `run-all.sh` | Orchestrates and summarizes P0–P4 according to the current mode | None |

## Common Options

```bash
# Allow more catch-up lag and sample more blocks.
bash scripts/flashblocks/verify/p1-shadow.sh --lag=3 --samples=20

# Extend the observation window to expose low-frequency problems.
bash scripts/flashblocks/verify/p2-dryrun.sh --watch=120

# Switch from dry_run to enabled; remain enabled on success and restore on failure.
bash scripts/flashblocks/verify/p3-enabled.sh --switch

# Measure preconfirmation latency with ten transactions.
bash scripts/flashblocks/verify/p4-user-facing.sh --samples=10
```

## Implementation

All chain queries use `cast`, and all log counts use `rg`. `lib.sh` contains only
environment loading, output, and assertions. Exactly two things a shell cannot do live in
Go, both printing `key=value` lines for the shell to `eval`:

- `wscheck/` decides whether a Flashblocks broadcast port is actually sending data, which
  requires a WebSocket HTTP Upgrade handshake and RFC 6455 frame decoding.
  `gorilla/websocket` implements the protocol and is vendored.
- `txprobe/` measures preconfirmation latency. BSD `date` has no millisecond resolution,
  and a shell poll loop would fork `curl` and `jq` on every iteration, adding tens of
  milliseconds of its own to a number compared against a 1000ms gate. `cast` still signs
  the transaction; `txprobe` only submits the signed payload and polls. Standard library
  only, no dependencies.

`lib.sh` rebuilds either binary into `bin/` when its sources are newer, with `-mod=vendor`
and `GOTOOLCHAIN=local` so the build never reaches the network. `.envrc` prepends a pinned
Go toolchain to `PATH` for building the op-stack, and that binary is not always runnable
(macOS Family Controls can deny execution with EPERM while the file still looks
executable), so `lib.sh` asks each candidate for `go version` and uses the first that
answers. With no usable toolchain, only the checks needing these two helpers are skipped.

Both have unit tests: `cd scripts/flashblocks/verify/txprobe && go test ./...`, likewise
under `wscheck/`.

## Two Verification Conventions

**Use complete logs.** These scripts target newly started chains whose logs begin at
genesis, so total counts represent the chain's true history. Whether `InvalidPayload`
ever occurred can be determined directly from the total. Only values compared with
blocks produced during a window (builder delivery rate, Flashblock slice count, and
builder share in enabled mode) use before/after counts and subtraction.

When these scripts are reused on a long-running chain that switched modes repeatedly,
historical records are included. For example, if the chain previously ran in enabled
mode, P2's "no builder block was adopted on-chain" check counts that history and reports
FAIL. In this case, clear `data/logs`, restart the chain, and verify again; the relevant
check also displays this guidance.

**Use the `context` field.** rollup-boost logs
`returning block hash=… number=… context=<l2|builder>` for every getPayload. `context`
identifies the payload source ultimately put on-chain, and upstream integration tests
use the same field. It must always be `l2` in dry_run because builder blocks are compared
but not adopted; in enabled mode, the vast majority should be `builder`.

## The Six P2 Checks

P2 intentionally retains only six checks. Each independently detects a real problem,
and their order expresses their dependencies: a later conclusion is meaningless if an
earlier prerequisite fails.

1. rollup-boost is in `dry_run` (prerequisite)
2. op-node's Engine points to rollup-boost; otherwise the builder does not participate
3. the builder op-node is stopped; otherwise it competes with rollup-boost for
   op-rbuilder's auth RPC
4. block production speed is unaffected and no builder block is adopted on-chain
   (dry_run semantics)
5. **No builder block is marked INVALID** (the hard gate and core P2 claim)
6. the builder actually delivers candidate blocks; otherwise item 5's zero means
   "zero samples," not "zero defects"

Other checks were moved or removed deliberately. Slice configuration is a one-time
static check in P0. Flashblock slice counts and assembly errors affect only the
user-facing preconfirmation stream, which is only a shadow preview during dry_run, so P3
checks them after enabled activation. safe head / batcher / proposer health concerns the base chain rather than
Flashblocks, so P1 and routine monitoring cover it. Port listeners, bad-block counts,
and similar signals are detected first by one of the checks above and add no independent
coverage.

For a single manual command, the following approximates items 5 and 6 plus dry_run
semantics:

```bash
sed 's/\x1b\[[0-9;]*m//g' data/logs/rollup-boost.log | tail -3000 | rg -c \
  -e 'InvalidPayload' -e 'returning block.*context=builder' -e 'error getting payload from builder'
```

rollup-boost logs cannot show that the builder fell behind; they report only a missed
delivery, not its cause. Compare heights to diagnose it:
`cast bn --rpc-url $L2_RPC` versus `cast bn --rpc-url $RB_RPC`.

**The hard gate is validity, not equality.** After receiving a builder candidate,
op-geth independently replays every transaction and recomputes stateRoot, receiptsRoot,
and gasUsed, then compares them with the header. A mismatch returns INVALID. A VALID
result therefore means that the builder's execution semantics agree with op-geth for an
arbitrary builder-selected transaction set, which is stronger than requiring two blocks
to be identical. This is the cross-validation principle described in section 6 of the
planning document. `rpc.rs` converts INVALID into an error that reaches the
`error getting payload from builder error=InvalidPayload(...)` log line, so the script
counts `InvalidPayload` occurrences.

**This zero has limits.** Engine API statuses are `VALID`, `INVALID`, `SYNCING`, and
`ACCEPTED`. rollup-boost records evidence only for `INVALID` (`is_invalid()` in alloy is
`matches!(self, Invalid{..})`); it treats `SYNCING` and `ACCEPTED` as success. Therefore,
"no `InvalidPayload`" means **"none were classified as invalid,"** not "all were
verified." op-geth may not complete validation and may return `SYNCING` when a candidate
block's parent is unknown. This almost always results from the builder falling behind
and is detected indirectly, rather than equivalently, by item 6's delivery rate and
height difference.

**Delivery rate is secondary.** INVALID=0 may also mean that the builder delivered no
blocks: zero samples, not zero defects. The check must also confirm how many blocks
received candidates. Missing candidates are harmless in dry_run because op-geth blocks
are used anyway. In enabled mode, each miss triggers fallback: the chain remains safe,
but that block has no Flashblocks.

**The scripts do not check equality.** The builder has independent ordering and
Flashblock slicing strategies, so its blocks should differ from op-geth in enabled mode;
otherwise, integrating it provides no value. Different blocks are not a defect and do
not justify reconciliation logic. Use the Prometheus metrics described below to inspect
the full difference distribution; they are more accurate than a few log samples.

rollup-boost Prometheus metrics (`--metrics`; see `RB_METRICS_PORT`) provide delta
distributions such as `block_building_gas_delta` and `block_building_tx_count_delta`.
They do **not count invalid blocks**, so item 5 must count `InvalidPayload` in logs.

## Important Caveat

**P3's `--fallback-drill` is destructive and disabled by default.** In disabled mode,
rollup-boost stops sending every request to the builder, including FCU and newPayload,
so op-rbuilder disconnects completely from the chain. This topology has no P2P backfill,
so after restoration op-rbuilder cannot obtain missing blocks and its head remains
permanently stuck. A 12-second drill has been observed to leave it 30+ blocks behind
without automatic recovery. Recovery requires a full
`off → switch-to-flashblocks-dryrun.sh` rebuild. The default fallback verification reads
existing logs and checks that every builder failure corresponds to a `context=l2` block,
without inducing a failure.
