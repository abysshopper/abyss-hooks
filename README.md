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

Pools use zero LP fees. CI deploys fresh actual V6 launch infrastructure on a public-chain fork, launches each example with real WETH, and checks hook-delta accounting and royalty payouts in both currency modes. The dynamic hook's [response matrix](hooks/dynamic-fee/review.md#expanded-response-verification) checks 4,224 actual charged swaps across eight policies, four price rises, three observation intervals, eleven idle durations and both trade directions. Sequential trading also checks oracle-clamp catch-up, return to the minimum and reactivation. Historical deployed V5 infrastructure is not upgraded or relabelled.

CI uses the [dRPC public Robinhood endpoint](https://drpc.org/chainlist/robinhood-mainnet-rpc) because the default public RPC can reject fork reads with a Cloudflare challenge. Local qualification accepts `--rpc-url https://robinhood.drpc.org`; the chain ID, fork block and deployed-code hash checks remain mandatory, and evidence records the selected endpoint.

Maintainers review each submission. Production registry admission requires separate approval.
