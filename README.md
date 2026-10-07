![Abyss](assets/abyss-social.webp)

# Abyss Hooks

Contribute pool-bound Uniswap V4 fee hooks to Black Market.

## Submit a hook

1. Copy the [static example](hooks/reference-bound) or [DynamicFeeHook example](hooks/dynamic-fee) into `hooks/<your-hook>`.
2. Declare your author payment and any custom fee schedule; complete `hook.json`, `integration.json`, and `review.md`.
3. Run the checks below and open a pull request.

See [CONTRIBUTING.md](CONTRIBUTING.md) for hook requirements and developer royalty terms.

The shared base is oracle-free. The dynamic example opts into the [abstract truncated-oracle template](CONTRIBUTING.md#optional-truncated-oracle) to raise fees on faster observed price rises; it compiles into the same submitted hook, not another deployment.

## Run the checks

Requires Python 3.12 and the [pinned Foundry release](CONTRIBUTING.md#local-checks).

```sh
python -m pip install -r scripts/requirements.txt
scripts/install-deps.sh
python scripts/check_hooks.py --output evidence/qualification
```

Pools use zero LP fees. CI launches each example with a WETH pool, exercises hook-delta fees in both currency modes, and checks accounting and royalty payouts.

Maintainers review each submission. Production registry admission requires separate approval.
