#!/bin/bash
# Copies the EIP-8483 proof of possession verifier from a checkout of
# leanxmss-evm-verifier into test/vectors/pq_proof_of_possession/.
#
#     ./scripts/pq_verifier.sh <path to leanxmss-evm-verifier>
#
# The verifier is the Solidity contract that the pq_registrations and
# pq_builder_registrations contracts call. It is built there, with the compiler
# settings pinned in its contracts/foundry.toml. This script writes its runtime
# code (main.hex), its init code (ctor.hex), the proofs of possession the tests
# use (leanxmss_pop.json) and the commit they come from (COMMIT).
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <path to leanxmss-evm-verifier>"
  exit 1
fi

src=$(cd "$1" && pwd)
dest="$(cd "$(dirname "$0")/.." && pwd)/test/vectors/pq_proof_of_possession"
dist=$(mktemp -d)
trap 'rm -rf "$dist"' EXIT

"$src/contracts/scripts/export-bytecode.sh" "$dist"

# The exported files are 0x-prefixed. The .hex files here have no prefix, like
# the ones in bytecode/.
mkdir -p "$dest"
printf '%s' "$(sed 's/^0x//' "$dist/PQProofOfPossession.bin-runtime")" > "$dest/main.hex"
printf '%s' "$(sed 's/^0x//' "$dist/PQProofOfPossession.bin")" > "$dest/ctor.hex"
cp "$src/contracts/test/vectors/leanxmss_pop.json" "$dest/leanxmss_pop.json"

commit=$(git -C "$src" rev-parse HEAD)
if [ -n "$(git -C "$src" status --porcelain)" ]; then
  commit="$commit-dirty"
fi
echo "$commit" > "$dest/COMMIT"
echo "copied the proof of possession verifier at $commit"
