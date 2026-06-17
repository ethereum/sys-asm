#!/bin/bash

declare -A expected
expected[src/beacon_root/main.eas]=f9509ecf1e15849b0da493f97e7769c1fd18854e96a127274dd9431dfc0afeee
expected[src/beacon_root/ctor.eas]=056278b1647d2a5fa69b104e9674a03bed0a629014858c23fd0ac686d82fe4c8
expected[src/withdrawals/main.eas]=849cd3e45f964a2273f8eb07734185fc0fd5189749067ccfa4a7cb7888aa7eed
expected[src/withdrawals/ctor.eas]=3064db2c39ec380b5ca376d1088f8423adba3da558e292dc20d3a859487b383a
expected[src/consolidations/main.eas]=b13f72eb2c14d4bd2fe720e7daa11aeaffa04ed3ce997f7e59df54e752f632c6
expected[src/consolidations/ctor.eas]=fdea0660574cf007a34cda1428af8929983390ec62484e43ef19f2c0738e9837
expected[src/execution_hash/main.eas]=142974bb25de5f7dc48119f143c66df0e28f8ec84b9d9f1a4ab3b7d5ebd95bfa
expected[src/execution_hash/ctor.eas]=ac6d34495b7985b0f050fe7ed28a5f42e383237c304a4c93ce0de4cd9a1ce45f

# This script compiles all system contracts using geas and verifies their
# bytecode hashes against known values.

set -e

if [ -z "$GEAS" ]; then
  GEAS="geas"
fi
if ! command -v $GEAS &> /dev/null; then
  echo "geas not found, installing..."
  go install github.com/fjl/geas/cmd/geas@latest
  GEAS=$(go env GOPATH)/bin/geas
  echo "GEAS=$GEAS"
fi

fail=0
for file in "${!expected[@]}"; do
  got=$($GEAS -a -stackcheck "$file" | sha256sum | cut -d' ' -f1)
  want=${expected[$file]}
  if [ "$got" = "$want" ]; then
    echo "OK  $file"
  else
    echo "FAIL $file"
    echo "  want: $want"
    echo "  got:  $got"
    fail=1
  fi
done

if [ $fail -ne 0 ]; then
  echo
  echo "hash check failed"
  exit 1
fi
