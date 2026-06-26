# `sys-asm`

This repository stores [`geas`][geas] implementations of Ethereum's system
contracts, such as the ones associated with [EIP-7002][7002] and
[EIP-7251][7251].

## Getting Started

To setup a dev environment capable of assembling and testing the contracts,
you will need to install [`foundry`][foundry] and a Go toolchain.

```console
$ curl -L https://foundry.paradigm.xyz | bash
```

## Building bytecode

To build all contracts, run `make`:

```console
$ make
...

$ cat bytecode/beacon_root/main.hex
3373fffffffffffffffffffffffffffffffffffffffe14604b57602036146024575f5ffd5b5f358015604757611fff810690815414603b575f5ffd5b611fff01545f5260205ff35b5f5ffd5b611fff42064281555f3590611fff015500
```

The bytecode must be committed alongside any assembly code changes.
For contracts which are already deployed, the bytecode is not allowed to change,
so any refactorings, etc. must ensure it is unmodified.

## Testing

The tests can be executed using `make test`:

```console
$ make test
[⠒] Compiling...
[⠒] Compiling 1 files with 0.8.14
[⠢] Solc 0.8.14 finished in 976.49ms
Compiler run successful!

Running 5 tests for test/Contract.t.sol:ContractTest
[PASS] testFakeExpo() (gas: 16063)
[PASS] testFee() (gas: 449136269)
[PASS] testInvalidRequest() (gas: 17248)
[PASS] testQueueReset() (gas: 7170334)
[PASS] testRequest() (gas: 152821)
Test result: ok. 5 passed; 0 failed; 0 skipped; finished in 870.90ms

Ran 1 test suites: 5 tests passed, 0 failed, 0 skipped (5 total tests)
```

You can also use the `forge` tool directly, but be aware that tests rely on the
bytecode created by `make build`, so you must recompile the contracts before running
tests.

## Deployment

System contracts are typically deployed using [Nick's method][nm] for predictable
deployment on all chains. To mine a deployment tx and address using this
technique, run the following:

```console
$ ./scripts/addr.sh withdrawals
searching for withdrawals deployment data
New highscore: 5
Sender: 0x96aeE04D69562D087EC52847Fc1a4FDAF2526002
Address: 0x0bb308c8c1F4933388CA65F63d941B76a829aAaA
Tx:
{
  "type": "0x0",
  "nonce": "0x0",
  "to": null,
  "gas": "0x3d090",
  "gasPrice": "0xe8d4a51000",
  "maxPriorityFeePerGas": null,
  "maxFeePerGas": null,
  "value": "0x0",
  "input": "0x61049d5f5561013280600f5f395ff33373fffffffffffffffffffffffffffffffffffffffe146090573615156028575f545f5260205ff3
5b366038141561012e5760115f54600182026001905f5b5f82111560595781019083028483029004916001019190603e565b90939004341061012e576001
54600101600155600354806003026004013381556001015f3581556001016020359055600101600355005b6003546002548082038060101160a457506010
5b5f5b81811460dd5780604c02838201600302600401805490600101805490600101549160601b83528260140152906034015260010160a6565b91018092
1460ed579060025560f8565b90505f6002555f6003555b5f548061049d141561010757505f5b60015460028282011161011c5750505f610122565b016002
90035b5f555f600155604c025ff35b5f5ffd",
  "v": "0x1b",
  "r": "0x539",
  "s": "0x2a68889c60a01e96",
  "hash": "0x7e28e6a01f362160d9916ee19ed9079d46b0773d91fc80245edcec6dd855ffd7"
}
```

To deploy this transaction, simply fund the "sender" account and submit the tx
to the network.

[geas]: https://github.com/fjl/geas
[7002]: https://eips.ethereum.org/EIPS/eip-7002
[7251]: https://eips.ethereum.org/EIPS/eip-7251
[foundry]: https://getfoundry.sh/
[forge]: https://github.com/foundry-rs/foundry/blob/master/forge
[nm]: https://yamenmerhi.medium.com/nicks-method-ethereum-keyless-execution-168a6659479c
