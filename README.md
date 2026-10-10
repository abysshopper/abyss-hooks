![Abyss](assets/abyss-social.webp)

# Abyss Hooks

Contribute pool-bound Uniswap V4 fee hooks to Black Market.

## Submit a hook

1. Copy the [static example](hooks/reference-bound) or [DynamicFeeHook example](hooks/dynamic-fee) into `hooks/<your-hook>`.
2. Declare your author payment and any custom fee schedule; complete `hook.json`, `integration.json`, and `review.md`.
3. Run the checks below and open a pull request.

See [CONTRIBUTING.md](CONTRIBUTING.md) for hook requirements and developer royalty terms.

The shared base is oracle-free. The dynamic example opts into the [abstract truncated-oracle template](CONTRIBUTING.md#optional-truncated-oracle) to raise fees on faster observed price rises. Creators choose independent minimum, maximum and sensitivity per pool, frozen at launch. It remains one submitted hook, not another deployment.

## Run the checks

Requires Python 3.12 and the [pinned Foundry release](CONTRIBUTING.md#local-checks).

```sh
python -m pip install -r scripts/requirements.txt
scripts/install-deps.sh
python scripts/check_hooks.py --output evidence/qualification
```

Pools use zero LP fees. The local qualification runner creates isolated Black Market launch contracts from the external source snapshot in `contracts/protocol/`, uses the fork's real manager, oracle factory and WETH, and checks hook-delta accounting and royalty payouts. These test deployments are not production registry admission. The dynamic hook's [response matrix](hooks/dynamic-fee/review.md#expanded-response-verification) checks 4,224 actual charged swaps across eight policies, four price rises, three observation intervals, eleven idle durations and both trade directions. Sequential trading also checks oracle-clamp catch-up, return to the minimum and reactivation.

Additional [granular regressions](hooks/dynamic-fee/review.md#granular-boundaries-and-trading) execute every second of total signal age from 2 through 300, adjacent-second cap/floor transitions, adjacent raw-unit fee rounding, variable-size exact-input/output swaps, continuous mixed trading and same-timestamp blocks.

Local qualification accepts `--rpc-url https://robinhood.drpc.org` because the default public RPC can reject fork reads with a Cloudflare challenge. Chain ID, fork block and deployed-code hash checks remain mandatory.

Automatic CI is temporarily paused. The Hooks workflow is retained for deliberate manual runs after re-enabling it; do not dispatch CI or wait for missing checks during the pause. Run applicable checks locally and disclose that GitHub CI did not run.

Maintainers review each submission. Production registry admission requires separate approval.

## AI agent guidance

[AGENTS.md](AGENTS.md) and the portable skills in `.agents/skills/` are generated with [rulesync](https://rulesync.dyoshikawa.com/). The skills cover hook authoring, qualification, PR review, audit-informed V4 hook security review, and rulesync maintenance. Authoring and security-review guidance link official Uniswap documentation and publicly available audits; using them does not constitute an independent audit. Apply the [PR review skill](.agents/skills/pr-review/SKILL.md) to the complete diff before opening a PR or pushing updates. Self-review does not replace independent maintainer review; inspect exact-head CI when enabled and disclose actual local evidence while it is paused.

Edit `.rulesync/rules/overview.md` or `.rulesync/skills/<name>/SKILL.md`, not the generated files. With Node.js 22 or later, regenerate and check for drift from the repository root:

```sh
npx --yes rulesync@27.0.0 generate
npx --yes rulesync@27.0.0 generate --check
```

Commit `.rulesync/`, `rulesync.jsonc`, `AGENTS.md`, and `.agents/skills/` together so guidance works on a fresh checkout. `rulesync.jsonc` enables only the AGENTS.md and Agent Skills standards; no MCP servers, automatic command hooks, or permissions are configured. Personal overrides go in ignored `rulesync.local.jsonc`.

Generation does not delete existing files. When removing or renaming a canonical skill, explicitly remove its obsolete generated copy. Do not run `rulesync gitignore`, which would ignore outputs this repository intentionally commits.
