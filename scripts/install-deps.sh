#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
install_dependency() {
  local name=$1 repository=$2 revision=$3 target="$root/contracts/lib/$1"
  if [[ ! -d "$target" ]]; then
    mkdir -p "$root/contracts/lib"
    git clone --no-checkout "$repository" "$target"
    git -C "$target" checkout --detach "$revision"
  fi
  [[ "$(git -C "$target" rev-parse HEAD)" == "$revision" ]] || {
    echo "Unexpected dependency revision: $name" >&2
    exit 1
  }
  git -C "$target" diff --quiet HEAD
}
install_dependency forge-std https://github.com/foundry-rs/forge-std.git 77041d2ce690e692d6e03cc812b57d1ddaa4d505
install_dependency v4-core https://github.com/Uniswap/v4-core.git 59d3ecf53afa9264a16bba0e38f4c5d2231f80bc
install_dependency solady https://github.com/vectorized/solady.git acd959aa4bd04720d640bf4e6a5c71037510cc4b
