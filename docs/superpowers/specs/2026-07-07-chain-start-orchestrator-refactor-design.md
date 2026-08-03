# Design: Refactor the chain-start Orchestration Layer to Invoke Individual run-op-* Component Scripts

- Date: 2026-07-07
- Status: Pending implementation (brainstorming review completed)
- Scope: Start/stop scripts under the repository root's `scripts/` directory and related documentation; **does not include source code in the `optimism/` submodule**
- Commit strategy: The user will commit the changes; neither this design nor its subsequent implementation will **commit automatically**

---

## 1. Background and Motivation

The project currently has **two parallel implementations of component startup logic**:

1. `scripts/chain-start.sh`: A one-command orchestration script that **inlines** the complete command-line flags for op-geth, op-node, op-batcher, and op-proposer, while also managing Anvil, JWT, `op-geth init`, readiness checks, PIDs, and logs.
2. `scripts/run-op-geth.sh` / `run-op-node.sh` / `run-op-batcher.sh` / `run-op-proposer.sh`: Four individual component launchers that each maintain another copy of the component flags for standalone debugging and restarts.

Maintaining separate copies of the flags means there is **no single source of truth**, and actual drift has already occurred:

| Component | Current chain-start.sh Value | Current run-op-*.sh Value | Problem |
|------|--------------------|------------------|------|
| op-proposer | `--game-type=${GAME_TYPE:-0}` (line 154) | `--game-type=${GAME_TYPE:-1}` (line 12) | The defaults differ, giving opposite initial permissioned/permissionless semantics |
| op-geth | The orchestration layer performs idempotent initialization with `if [ ! -d geth ]` | Unconditional `op-geth init` (line 10) | The standalone script attempts initialization on every run |

The maintenance burden and drift risk will only increase as component flags evolve. The user has explicitly identified the issue and proposed the direction: **have `chain-start.sh` invoke the four `run-op-*.sh` scripts directly, consolidating component flags into a single source of truth.**

---

## 2. Goals and Non-goals

### 2.1 Goals

1. **Single source of truth**: Define each component's runtime flags only in its `run-op-<c>.sh`; `chain-start.sh` will no longer inline component flags.
2. **Clear layering**:
   - `chain-start.sh` = orchestration layer (environment assembly + lifecycle management).
   - `run-op-<c>.sh` = pure component launcher (responsible only for starting one process with the correct flags).
3. **Eliminate known drift**: Standardize the proposer `--game-type` default and ownership of `op-geth init`.
4. **Consistent naming**: Standardize the `local/server` terminology in scripts and documentation to `local/remote` (explicitly requested by the user).
5. **Behavioral equivalence**: After the refactor, the command lines for the four processes started by `chain-start.sh` must be **textually identical** to those before the refactor, except for intentionally resolved drift described in Section 5.

### 2.2 Non-goals

1. **Do not modify any source code in the `optimism/` submodule** (deployment resets the submodule with `git checkout`, so such changes would be lost).
2. **Do not alter validated core orchestration logic**: Preserve Anvil startup, JWT generation, the idempotent `op-geth init` check, readiness waits, PID/log management, and the `config/<context>/` configuration loading path.
3. **Do not introduce a new process management framework** such as systemd, Supervisor, or Docker Compose.
4. **Do not change the runtime semantics of flags**: Ports, private keys, DA type, and other values remain based on the current `chain-start.sh` values.
5. **Do not perform unrelated refactoring**: Do not opportunistically reorganize directories or change unrelated script styles.

---

## 3. Architecture and Responsibilities

### 3.1 Layering Diagram

```
                bash scripts/chain-start.sh [local|remote]
                                │
          ┌─────────────────────┴──────────────────────┐
          │       Orchestration layer (chain-start.sh)     │
          │  - local/remote parsing; Anvil (local only)    │
          │  - config/<context>/ path assembly + export    │
          │  - JWT generation; op-geth init (idempotent)   │
          │  - Readiness waits, PID records, log redirects │
          └───┬──────────┬───────────┬──────────┬────────┘
              │ export env + nohup ... &         │
     ┌────────▼───┐ ┌────▼─────┐ ┌───▼──────┐ ┌─▼──────────┐
     │run-op-geth │ │run-op-   │ │run-op-   │ │run-op-      │
     │   .sh      │ │ node.sh  │ │batcher.sh│ │proposer.sh │
     │(launcher)  │ │(launcher)│ │(launcher)│ │(launcher)   │
     └─────┬──────┘ └────┬─────┘ └────┬─────┘ └─────┬──────┘
           │ exec        │ exec       │ exec        │ exec
        op-geth       op-node     op-batcher    op-proposer
```

For standalone debugging, run `bash scripts/run-op-<c>.sh` directly, provided that `chain-setup` has generated the configuration and the JWT and geth datadir already exist.

### 3.2 Responsibility Boundaries

| Responsibility | Owner | Description |
|------|------|------|
| local/remote detection | chain-start | Standalone scripts do not detect the environment |
| Anvil start/stop | chain-start (local only) | run-op-* does not interact with L1 |
| Configuration path assembly (`DEPLOYMENT_CONFIG_PATH`, genesis/rollup/artifact) | chain-start, passed through exports | run-op-* only consumes values |
| JWT generation | chain-start | run-op-* only reads the JWT file |
| `op-geth init` | chain-start (idempotent, first run only) | **Removed from run-op-geth** |
| Readiness wait (geth Engine RPC) | chain-start | run-op-* does not wait |
| PIDs/logs | chain-start (`nohup ... & ; echo $! > pid`) | run-op-* uses `exec`, so the PID belongs to the component process |
| **Component flag definitions** | **run-op-<c>.sh (single source of truth)** | chain-start no longer inlines them |

---

## 4. Environment Propagation Conventions

Both `chain-start.sh` and `run-op-*.sh` run `source .envrc`. The conflict is that the orchestration layer **overrides some values at runtime** (for example, local mode changes `L1_RPC_URL` to `http://localhost:8545` and points configuration paths to `config/<context>/`). If run-op-* uses the original `.envrc` values after sourcing it again, it will diverge from the orchestration layer.

### 4.1 Convention: Orchestration Overrides Take Precedence, with `.envrc` as the Fallback

Use the `_CALLER_*` propagation pattern: the orchestration layer exports overridden key variables as `_CALLER_<VAR>`; after `source .envrc`, run-op-* uses the caller-provided value when present and otherwise falls back to the `.envrc` value.

Value resolution pattern in run-op-* (example):

```bash
source .envrc
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
# Derive fallback configuration files (rollup/artifact) from config/<context>/, not the deployments artifacts referenced by .envrc:
OP_NODE_ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/rollup.json}"
DEPLOYMENT_OUTFILE="${_CALLER_DEPLOYMENT_OUTFILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/artifact.json}"
```

- When invoked by `chain-start`, `_CALLER_*` values are exported, so the launcher receives the correct orchestration-layer overrides (the config directory).
- When `bash scripts/run-op-<c>.sh` runs independently, `_CALLER_*` is empty, and configuration files still fall back to values derived from `config/<context>/` (consistent with the orchestration layer).

> **Important**: In `.envrc`, `OP_NODE_ROLLUP_FILE`, `DEPLOYMENT_OUTFILE`, and `OP_GETH_GENESIS_FILE` point by default to
> `optimism/packages/contracts-bedrock/deployments/` (the **raw artifacts** from the deployment build). At runtime, however,
> `chain-start.sh` and this project consistently use `config/<context>/` (the **canonical configuration**, tracked by Git and
> patched through the runbook). Therefore, the run-op-* fallback **must not** use `$OP_NODE_ROLLUP_FILE` from `.envrc` directly;
> it must derive the path again from `DEPLOYMENT_CONFIG_PATH` (the config directory).

### 4.2 Variables That Must Be Passed Through `_CALLER_*`

Variables that the orchestration layer overrides or computes at runtime and that run-op-* requires:

| Variable | Orchestration-layer Source | Consumer |
|------|-----------|--------|
| `L1_RPC_URL` | Overridden to `http://localhost:8545` in local mode | node / batcher / proposer |
| `DEPLOYMENT_CONFIG_PATH` | `config/$DEPLOYMENT_CONTEXT` | geth / node |
| `OP_GETH_GENESIS_FILE` | `$DEPLOYMENT_CONFIG_PATH/genesis.json` | geth (initialization is already handled by the orchestration layer; fallback only) |
| `OP_NODE_ROLLUP_FILE` | `$DEPLOYMENT_CONFIG_PATH/rollup.json` | node |
| `DEPLOYMENT_OUTFILE` | `$DEPLOYMENT_CONFIG_PATH/artifact.json` | proposer (reads factory/l2oo addresses) |
| `OP_GETH_DATA_PATH` | `$DATA_DIR/op-geth` | geth (datadir and JWT) |
| `JWT_FILE` | `$OP_GETH_DATA_PATH/jwt.txt` | geth / node |
| `SAFEDB_PATH` | `$DATA_DIR/op-node/safedb` | node |

> Note: `GAME_TYPE`, `USE_FAULT_PROOFS`, `PROPOSAL_INTERVAL`, the `GS_*` private keys, and similar values come from `.envrc` and are not overridden by the orchestration layer. run-op-* can use the `.envrc` values directly without `_CALLER_*`.

---

## 5. Component-level Changes (run-op-*.sh Becomes the Single Source of Truth for Flags)

Principle: Use the flags **currently** inlined in `chain-start.sh` as the baseline and migrate them verbatim into the corresponding run-op-* scripts, standardizing values only at the intentionally resolved drift points listed below.

### 5.1 run-op-geth.sh

- **Remove** the `op-geth init` block (lines 7–10): the orchestration layer handles initialization idempotently; standalone execution requires an initialized datadir.
- Align flags with line 111 of chain-start (the two are effectively equivalent today, and both use `$OP_GETH_DATA_PATH/jwt.txt` as the JWT path).
- **Fork override extension point**: Append `${OP_GETH_OVERRIDE_FLAGS:-}` to the flags for hardfork-time overrides such as Jovian (see Section 6.2).
- End with `exec op-geth $flags` so the PID belongs to op-geth itself.
- Add environment safeguards: after `source .envrc`, resolve `_CALLER_*` values with precedence as defined in Section 4.1.

### 5.2 run-op-node.sh

- Align flags with line 132 of chain-start (the two are already equivalent: JWT = `$BASE_PATH/data/op-geth/jwt.txt`, and safedb defaults to `$BASE_PATH/data/op-node/safedb`).
- Resolve `_CALLER_*` values for `L1_RPC_URL`, `OP_NODE_ROLLUP_FILE`, `SAFEDB_PATH`, and the JWT path with the precedence defined in Section 4.1.
- End with `exec op-node $flags`.

### 5.3 run-op-batcher.sh

- Align flags with line 142 of chain-start (they are already textually identical, with no drift).
- Resolve the `_CALLER_*` value for `L1_RPC_URL` with the precedence defined in Section 4.1.
- End with `exec op-batcher $flags`.

### 5.4 run-op-proposer.sh

- Align flags with lines 153–155 of chain-start.
- **Resolve the drift**: Standardize the `--game-type` default as `${GAME_TYPE:-1}` (start in permissioned mode, consistent with `GAME_TYPE=1` in `.envrc` and `respectedGameType=1` at deployment). Use the current run-op-proposer value of `:-1`; **the inlined `:-0` in chain-start will be removed by this refactor** when that entire branch is migrated.
- Resolve `_CALLER_*` values for `L1_RPC_URL` and `DEPLOYMENT_OUTFILE` with the precedence defined in Section 4.1.
- Preserve the existing anchor explanation comment.
- End with `exec op-proposer $flags`.

### 5.5 chain-start.sh (Orchestration Layer)

**Preserve**: `local/remote` parsing, Anvil (local only), `config/<context>/` configuration assembly and exports, JWT generation, `op-geth init` (idempotent and only on the first run), geth Engine readiness waits, the `SKIP_BATCHER`/`SKIP_PROPOSER` switches, and PID/log management.

**Replace**: Change the four inlined `nohup op-<c> $FLAGS >> log &` blocks to:

```bash
# Pass key variables after orchestration-layer overrides
export _CALLER_L1_RPC_URL="$L1_RPC_URL"
export _CALLER_DEPLOYMENT_OUTFILE="$DEPLOYMENT_OUTFILE"
export _CALLER_OP_NODE_ROLLUP_FILE="$OP_NODE_ROLLUP_FILE"
export _CALLER_SAFEDB_PATH="$SAFEDB_PATH"
# ... (according to the list in Section 4.2)

nohup bash "$SCRIPT_DIR/run-op-geth.sh" >> "$LOG_DIR/op-geth.log" 2>&1 &
echo $! > "$PID_DIR/op-geth.pid"
```

All four components follow this pattern. Because run-op-* uses `exec`, the PID recorded in `$!` ultimately belongs to the component process itself, preserving the PID and signature matching used by `chain-stop.sh` (see Section 6.1).

### 5.6 Rename local/server to local/remote

- `chain-start.sh` / `chain-setup.sh`: Replace `server` with `remote` in `CHAIN_ENV` values, usage messages, and comments; set `CHAIN_ENV=remote` in the else branch of automatic detection.
- `chain-stop.sh`: Replace `server` with `remote` in messages (no functional logic depends on this literal).
- **Do not retain a `server` compatibility alias** (final decision): Switch directly to `local/remote`; old `... server` commands will produce a usage error. The README must highlight this breaking change. The argument validation branch accepts only `local` / `remote`, and the else branch of automatic detection sets `CHAIN_ENV=remote`.

---

## 6. Compatibility

### 6.1 chain-stop.sh Compatibility

`chain-stop.sh` has two paths:
1. Read `$PID_DIR/<c>.pid` for an exact kill. Because run-op-* uses `exec`, `$!` is the component PID, so this **remains effective**.
2. Fall back to process-signature matching (`--datadir=`, `--safedb.path=`, `--rollup-rpc= + --rpc.port=`, and so on). These signatures are **preserved unchanged** when flags move into run-op-*, so matching **remains effective**.

⚠️ Validation point: Ensure the migrated run-op-* scripts retain the signatures required by chain-stop (proposer's `--rpc.port=8560`, batcher's `--rpc.port=$OP_BATCHER_PORT`/`--rollup-rpc=`, node's `--safedb.path=`, and geth's `--datadir=`). The textual equivalence check in Section 7 covers this.

### 6.2 Jovian Fork-override Compatibility

`scripts/jovian/README.md` currently contains a Python tutorial that directly **text-patches** the `OP_GETH_FLAGS` line in `chain-start.sh` to insert `--override.*` (corresponding to the commented example on lines 112–113 of chain-start). After the refactor, flags no longer live in chain-start, so the injection point must change:

**Selected approach (environment variable injection)**:
- Append `${OP_GETH_OVERRIDE_FLAGS:-}` to the run-op-geth flags (see Section 5.1).
- Update the Jovian tutorial to write override flags to `.envrc` as `export OP_GETH_OVERRIDE_FLAGS="--override.fjord=... --override.jovian=..."` (Python updates this variable in `.envrc` with sed/a regular expression instead of patching a script line).
- Benefit: The injection target changes from a specific script line to an environment variable, decoupling it from the source of truth for flags and making it effective for both chain-start and standalone run-op-geth execution.

### 6.3 Documentation Updates

- `README.md`: Change the terminology from `server` to `remote`; document the prerequisites for running `run-op-<c>.sh` directly (run chain-setup first and ensure the JWT/datadir already exist).
- `scripts/jovian/README.md`: Use the `OP_GETH_OVERRIDE_FLAGS` injection method from Section 6.2.

---

## 7. Validation Plan

1. **Textual equivalence check (core)**: Before and after the refactor, use `set -x` or print the final command line before `exec` in run-op-* and **diff** the geth/node/batcher/proposer commands. They must be identical except for these intentional differences:
   - Standardize proposer `--game-type` to `1` (resolving drift).
   - The geth launcher no longer performs initialization.
2. **End-to-end**: Start from scratch with `bash scripts/chain-start.sh local` → all four processes remain alive, op-geth produces blocks, op-batcher submits, and op-proposer successfully creates a game (without `AnchorRootNotFound`).
3. **Stop**: `bash scripts/chain-stop.sh` terminates all four processes (validate both PID-based and signature-based paths).
4. **Standalone regression**: Each `bash scripts/run-op-<c>.sh` invocation (with `_CALLER_*` empty) can start its component using `.envrc` values.
5. **Jovian injection**: After setting `OP_GETH_OVERRIDE_FLAGS`, the geth command line correctly includes `--override.*` at the end.
6. **Idempotency**: Repeated `chain-start` invocations neither reinitialize the geth datadir nor regenerate the JWT.

---

## 8. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|------|------|
| A flag is omitted during migration, changing component behavior | Block production, submission, or game creation fails | Enforce textual equivalence through the diff in Section 7.1 |
| A `_CALLER_*` value is not propagated, causing run-op-* to use the wrong original `.envrc` value (such as L1_RPC_URL in local mode) | Connects to the wrong L1 | Export each item in the Section 4.2 checklist; the standalone test in Section 7.4 covers fallback paths |
| chain-stop signatures no longer match after migration | Processes remain running | Section 6.1 validation point + Section 7.3 stop test |
| Incorrect `exec` usage records the wrong PID | chain-stop cannot terminate the process | End each run-op-* with `exec`, making `$!` the component PID; validate in Section 7.3 |
| Renaming local/server without an alias breaks existing `... server` invocations | Commands fail with an error | Prominently document the breaking change in README; update all repository call sites found by a global search for `server` |
| The old patch stops working after the Jovian tutorial changes injection points | Fork overrides do not take effect | Update `scripts/jovian/README.md` at the same time; validate in Section 7.5 |

---

## 9. Final Decisions

1. Standardize the proposer `--game-type` default as `1` (start in permissioned mode).
2. Rename `local/server` to `local/remote`, with **no `server` compatibility alias**.

(All open questions have been resolved, and the design is final.)
