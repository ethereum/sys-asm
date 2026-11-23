// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./Test.sol";
import {Vm} from "forge-std/Vm.sol";

// The address the registration contracts call to check a proof of possession.
address constant verifier = 0x848300000000000000000000000000000000fFfF;

uint256 constant last_block_slot = 4;
uint256 constant pq_queue_storage_offset = 5;
uint256 constant inhibitor = uint256(bytes32(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff));

uint256 constant pubkey_size = 48;
uint256 constant signed_size = 80; // pubkey ++ xmss_pubkey
uint256 constant proof_size = 2404;
uint256 constant system_call_gas_limit = 30_000_000;

string constant vectors_dir = "test/vectors/pq_proof_of_possession/";

// PQRegistrationTest holds the tests shared by the two EIP-8483 contracts, the
// one for validators and the one for builders. They differ in the size of
// pq_data and in the fee and queue parameters.
//
// The verifier is the Solidity contract from leanxmss-evm-verifier, and the
// requests carry the proofs of possession generated there. Both are copied
// into test/vectors/pq_proof_of_possession/ by scripts/pq_verifier.sh.
abstract contract PQRegistrationTest is Test {
  // The requests of the three valid proofs.
  bytes[3] requests;
  string vectors;

  function setUp() public {
    vm.etch(addr, readHex(string.concat("bytecode/", bytecodeDir(), "/main.hex")));
    vm.etch(verifier, readHex(string.concat(vectors_dir, "main.hex")));
    vm.etch(fakeExpo, readHex("bytecode/fake_expo_test/main.hex"));

    // A proof signs the chain id, so the proofs are only valid on the chain
    // they were generated for.
    vectors = vm.readFile(string.concat(vectors_dir, "leanxmss_pop.json"));
    assertEq(block.chainid, vm.parseJsonUint(vectors, ".chainId"));
    for (uint256 i = 0; i < 3; i++) {
      requests[i] = makeRequestAt(string.concat(".proofs[", vm.toString(i), "]"));
    }
  }

  // --------------------------------------------------------------------------
  // parameters ---------------------------------------------------------------
  // --------------------------------------------------------------------------

  function bytecodeDir() internal pure virtual returns (string memory);
  function pqDataSize() internal pure virtual returns (uint256);
  function targetPerBlock() internal pure virtual returns (uint256);
  function maxAddsPerBlock() internal pure virtual returns (uint256);
  function maxPerBlock() internal pure virtual returns (uint256);

  function inputSize() internal pure returns (uint256) {
    return pubkey_size + pqDataSize();
  }

  function recordSize() internal pure returns (uint256) {
    return 20 + inputSize();
  }

  // slotsPerItem is one slot for the source address, plus the input in 32-byte
  // words.
  function slotsPerItem() internal pure returns (uint256) {
    return 1 + (inputSize() + 31) / 32;
  }

  // --------------------------------------------------------------------------
  // requests -----------------------------------------------------------------
  // --------------------------------------------------------------------------

  // testInvalidRequest checks that common invalid requests are rejected.
  function testInvalidRequest() public {
    bytes memory req = makeRequest(0);

    // request too small
    (bool ret,) = addr.call{value: 1}(hex"1234");
    assertEq(ret, false);

    // input without the proof
    (ret,) = addr.call{value: 1}(slice(req, 0, inputSize()));
    assertEq(ret, false);

    // proof without the input
    (ret,) = addr.call{value: 1}(slice(req, inputSize(), proof_size));
    assertEq(ret, false);

    // one byte short
    (ret,) = addr.call{value: 1}(slice(req, 0, req.length - 1));
    assertEq(ret, false);

    // one byte long
    (ret,) = addr.call{value: 1}(bytes.concat(req, hex"00"));
    assertEq(ret, false);

    // ABI-style call (4-byte selector prefix)
    (ret,) = addr.call{value: 1}(bytes.concat(hex"deadbeef", req));
    assertEq(ret, false);

    // fee too small
    (ret,) = addr.call{value: 0}(req);
    assertEq(ret, false);

    assertStorage(count_slot, 0, "expected no requests enqueued");
    assertStorage(queue_tail_slot, 0, "expected no requests enqueued");
  }

  // testRequest verifies a single request is accepted, logged and read
  // successfully, and that the proof is neither stored nor logged.
  function testRequest() public {
    bytes memory req = makeRequest(1);
    bytes memory record = makeRecord(address(this), req);
    assertEq(record.length, recordSize());

    vm.expectEmitAnonymous(false, false, false, false, true);
    assembly {
      log0(add(record, 32), mload(record))
    }

    addRequest(address(this), req, 1);
    assertStorage(excess_slot, 0, "unexpected excess");
    assertStorage(count_slot, 1, "unexpected request count");
    assertStorage(last_block_slot, block.number, "unexpected last block");
    assertEq(addr.balance, 1, "the contract keeps the fee");

    // Nothing is written past the request's slots. The first 16 bytes of the
    // proof would otherwise be in the last slot, and the rest after it.
    uint256 last = pq_queue_storage_offset + slotsPerItem() - 1;
    assertEq(load(last) & type(uint128).max, 0, "proof bytes in the last slot");
    assertStorage(last + 1, 0, "unexpected write past the request");

    bytes memory out = getRequests();
    assertEq(out, record, "unexpected record");
    assertStorage(queue_head_slot, 0, "expected queue head reset");
    assertStorage(queue_tail_slot, 0, "expected queue tail reset");
  }

  // testRequestRecordsCaller verifies the recorded source_address is the
  // caller, the field the consensus layer checks against the owner.
  function testRequestRecordsCaller() public {
    address caller = 0xCAfEcAfeCAfECaFeCaFecaFecaFECafECafeCaFe;
    bytes memory req = makeRequest(2);
    addRequest(caller, req, 1);

    bytes memory out = getRequests();
    assertEq(address(bytes20(slice(out, 0, 20))), caller, "source_address must be the caller");
    assertEq(slice(out, 20, inputSize()), slice(req, 0, inputSize()), "unexpected input");
  }

  // testOverpayment verifies the contract keeps all the value it is sent.
  function testOverpayment() public {
    addRequest(address(this), makeRequest(0), 5);
    assertEq(addr.balance, 5);
  }

  // testRequestWrites checks that a request writes only the fee state, the
  // queue tail and its own slots, and that the contract logs only the record.
  function testRequestWrites() public {
    for (uint256 i = 0; i < 3; i++) {
      bytes memory req = makeRequest(i);
      vm.record();
      vm.recordLogs();
      (bool ret,) = addr.call{value: 1}(req);
      assertEq(ret, true, "expected call to succeed");

      uint256 first = pq_queue_storage_offset + i*slotsPerItem();
      (, bytes32[] memory writes) = vm.accesses(addr);
      for (uint256 w = 0; w < writes.length; w++) {
        uint256 slot = uint256(writes[w]);
        bool header = slot == excess_slot || slot == count_slot || slot == queue_tail_slot || slot == last_block_slot;
        assertTrue(header || (slot >= first && slot < first + slotsPerItem()), "unexpected slot written");
      }

      // EIP-7708 also logs the transfer of the fee, so only the logs of the
      // contract are counted.
      Vm.Log[] memory logs = vm.getRecordedLogs();
      uint256 count = 0;
      for (uint256 l = 0; l < logs.length; l++) {
        if (logs[l].emitter != addr) {
          continue;
        }
        assertEq(logs[l].topics.length, 0, "unexpected log topics");
        assertEq(logs[l].data, makeRecord(address(this), req), "unexpected log data");
        count++;
      }
      assertEq(count, 1, "expected one log");
    }
  }

  // --------------------------------------------------------------------------
  // proof of possession ------------------------------------------------------
  // --------------------------------------------------------------------------

  // testInvalidProof checks that a request is rejected unless its proof was
  // signed by the leanXMSS key it registers, for the BLS key it registers.
  function testInvalidProof() public {
    bytes memory req = makeRequest(0);
    bytes memory other = makeRequest(1);

    // the BLS key of another proof
    addFailedRequest(address(this), splice(req, other, 0, pubkey_size), 1);

    // one bit of the BLS key changed
    addFailedRequest(address(this), flip(req, pubkey_size - 1), 1);

    // the leanXMSS key of another proof
    addFailedRequest(address(this), splice(req, other, pubkey_size, 32), 1);

    // one bit of the proof changed, at several places
    for (uint256 ost = 0; ost < proof_size; ost += 401) {
      addFailedRequest(address(this), flip(req, inputSize() + ost), 1);
    }

    // a signature of the same message at leaf 1, where a proof must be at leaf 0
    addFailedRequest(address(this), makeRequestAt(".wrongLeaf"), 1);

    // a signature of the message without its domain
    addFailedRequest(address(this), makeRequestAt(".noDomain"), 1);

    assertStorage(queue_tail_slot, 0, "expected no requests enqueued");
    addRequest(address(this), req, 1);
  }

  // testProofOtherChain checks that a proof is only valid on the chain it was
  // signed for.
  function testProofOtherChain() public {
    vm.chainId(1);
    addFailedRequest(address(this), makeRequest(0), 1);
  }

  // testFuzzChangedBit checks that a request with one bit changed is rejected,
  // wherever the bit is: in the pubkey, in the leanXMSS key or in the proof.
  // The exception is the data that the proof doesn't sign, which only
  // validator requests have.
  function testFuzzChangedBit(uint256 x, uint256 bit) public {
    bytes memory req = makeRequest(x);
    bit = bound(bit, 0, 8*req.length - 1);
    uint256 idx = bit / 8;
    req[idx] = req[idx] ^ bytes1(uint8(1 << (bit % 8)));

    bool unsigned = idx >= signed_size && idx < inputSize();
    (bool ret,) = addr.call{value: 1}(req);
    assertEq(ret, unsigned, "unexpected result for a changed bit");
  }

  // testFuzzRequestSize checks that calldata of any size other than a
  // request's is rejected: a request cut short, or with zeros after it.
  function testFuzzRequestSize(uint256 x, uint256 size) public {
    bytes memory req = makeRequest(x);
    size = bound(size, 0, req.length + 32);
    vm.assume(size != req.length);
    if (size > req.length) {
      req = bytes.concat(req, new bytes(size - req.length));
    }
    assembly {
      mstore(req, size)
    }
    (bool ret,) = addr.call{value: 1}(req);
    assertEq(ret, false, "expected request to fail");
  }

  // testVerifierInput checks which bytes the contract sends to the verifier:
  // the pubkey, the leanXMSS key and the proof. The verifier here accepts only
  // calldata with a given hash.
  function testVerifierInput() public {
    bytes memory req = makeRequest(0);
    bytes memory expected = bytes.concat(slice(req, 0, signed_size), slice(req, inputSize(), proof_size));
    assertEq(expected.length, signed_size + proof_size);

    vm.etch(verifier, hashVerifier(keccak256(expected)));
    addRequest(address(this), req, 1);

    // The same verifier rejects any other input.
    addFailedRequest(address(this), flip(req, 0), 1);
    vm.etch(verifier, hashVerifier(keccak256(bytes.concat(expected, hex"00"))));
    addFailedRequest(address(this), req, 1);
  }

  // testVerifierNotDeployed checks that requests are rejected when there is no
  // code at the verifier's address. A call to such an address succeeds and
  // returns nothing.
  function testVerifierNotDeployed() public {
    vm.etch(verifier, "");
    addFailedRequest(address(this), makeRequest(0), 1);

    // The contract reads the verifier's result from memory 0, which holds the
    // start of the pubkey when nothing is returned. A pubkey that starts with
    // the word 1 must not pass for a result.
    addFailedRequest(address(this), startsWithOne(makeRequest(0)), 1);
  }

  // testVerifierResult checks that the contract accepts a request only when
  // the call to the verifier succeeds and returns the 32-byte word 1.
  function testVerifierResult() public {
    bytes memory req = makeRequest(0);
    bytes memory one = startsWithOne(req);

    // STOP: succeeds and returns nothing
    vm.etch(verifier, hex"00");
    addFailedRequest(address(this), req, 1);
    addFailedRequest(address(this), one, 1);

    // revert(0, 0)
    vm.etch(verifier, hex"5f5ffd");
    addFailedRequest(address(this), req, 1);
    addFailedRequest(address(this), one, 1);

    // mstore(0, 1); revert(0, 32): reverts with the word 1
    vm.etch(verifier, hex"60015f5260205ffd");
    addFailedRequest(address(this), req, 1);

    // mstore(0, 0); return(0, 32): returns the word 0
    vm.etch(verifier, hex"5f5f5260205ff3");
    addFailedRequest(address(this), req, 1);
    addFailedRequest(address(this), one, 1);

    // mstore(0, 2); return(0, 32): returns the word 2
    vm.etch(verifier, hex"60025f5260205ff3");
    addFailedRequest(address(this), req, 1);

    // mstore(0, 1); return(0, 64): returns the word 1 and 32 more bytes
    vm.etch(verifier, hex"60015f5260405ff3");
    addFailedRequest(address(this), req, 1);

    // mstore(0, 1); return(1, 31): returns the low 31 bytes of the word 1
    vm.etch(verifier, hex"60015f52601f6001f3");
    addFailedRequest(address(this), req, 1);
    addFailedRequest(address(this), one, 1);

    // sstore(0, 1); mstore(0, 1); return(0, 32): fails, since the verifier is
    // called with STATICCALL. A write in a static call takes all the gas of
    // the call, so the request is sent with a gas limit.
    vm.etch(verifier, hex"60015f5560015f5260205ff3");
    (bool ret,) = addr.call{value: 1, gas: 1_000_000}(req);
    assertEq(ret, false, "expected request to fail");

    assertStorage(queue_tail_slot, 0, "expected no requests enqueued");

    // mstore(0, 1); return(0, 32): returns the word 1
    vm.etch(verifier, hex"60015f5260205ff3");
    addRequest(address(this), req, 1);
  }

  // testVerifierDeployment checks that the verifier's init code deploys the
  // runtime code the tests use.
  function testVerifierDeployment() public {
    address deployed = deploy(readHex(string.concat(vectors_dir, "ctor.hex")));
    assertEq(deployed.code, verifier.code);
  }

  // --------------------------------------------------------------------------
  // fee ----------------------------------------------------------------------
  // --------------------------------------------------------------------------

  // testDeployment checks that the constructor deploys the runtime code and
  // writes no storage, so the contract takes requests as soon as it is
  // deployed.
  function testDeployment() public {
    address deployed = deploy(readHex(string.concat("bytecode/", bytecodeDir(), "/ctor.hex")));
    assertEq(deployed.code, addr.code);
    for (uint256 slot = 0; slot < pq_queue_storage_offset; slot++) {
      assertEq(vm.load(deployed, bytes32(slot)), bytes32(0), "expected no storage written");
    }

    (bool ret, bytes memory data) = deployed.call("");
    assertEq(ret, true);
    assertEq(uint256(bytes32(data)), 1, "unexpected fee");
    (ret,) = deployed.call{value: 1}(makeRequest(0));
    assertEq(ret, true, "expected request to succeed");
  }

  // testFeeGetterRejectsValue verifies the empty-calldata fee getter reverts
  // when value is attached, preventing accidentally lost funds.
  function testFeeGetterRejectsValue() public {
    vm.deal(address(this), 1);
    (bool ret,) = addr.call{value: 1}("");
    assertEq(ret, false, "fee getter must reject callvalue");
  }

  // testFeePerTx checks how fees are computed within a single block, and that
  // no more than the maximum can be added in it.
  function testFeePerTx() public {
    for (uint256 i = 0; i < maxAddsPerBlock(); i++) {
      uint256 fee = getCurrentFee();
      if (i <= targetPerBlock()) {
        assertEq(fee, 1, "unexpected fee for request below target");
      } else {
        assertEq(fee, computeFee(i - targetPerBlock()), "unexpected fee");
        addFailedRequest(sender(i), makeRequest(i), fee-1);
      }
      addRequest(sender(i), makeRequest(i), fee);
    }
    assertStorage(count_slot, maxAddsPerBlock(), "unexpected request count");
    assertStorage(excess_slot, 0, "the excess is updated by the first request of a block");

    // The block is full.
    addFailedRequest(sender(0), makeRequest(0), 1 ether);

    // The next block takes requests again.
    vm.roll(block.number + 1);
    addRequest(sender(0), makeRequest(0), getCurrentFee());
  }

  // testFeeDecay checks that the excess decays by the target for every block
  // without requests, with no system call.
  function testFeeDecay() public {
    fillBlock(0);
    uint256 added = maxAddsPerBlock();

    uint256 excess = added;
    for (uint256 elapsed = 1; excess > 0; elapsed++) {
      vm.roll(block.number + 1);
      uint256 decay = elapsed * targetPerBlock();
      excess = added > decay ? added - decay : 0;
      assertEq(getCurrentFee(), computeFee(excess), "unexpected fee");
    }

    // The fee getter doesn't write. The first request of a block stores the
    // decayed excess, and counts as the first of its block.
    assertStorage(excess_slot, 0, "unexpected excess before the request");
    assertStorage(count_slot, added, "unexpected request count before the request");
    addRequest(sender(0), makeRequest(0), 1);
    assertStorage(excess_slot, 0, "unexpected excess");
    assertStorage(count_slot, 1, "unexpected request count");
    assertStorage(last_block_slot, block.number, "unexpected last block");
  }

  // testFeeAcrossBlocks checks that the requests of a block above the target
  // carry over to the next block as excess.
  function testFeeAcrossBlocks() public {
    fillBlock(0);
    vm.roll(block.number + 1);

    uint256 excess = maxAddsPerBlock() - targetPerBlock();
    for (uint256 i = 0; i < maxAddsPerBlock(); i++) {
      uint256 fee = getCurrentFee();
      uint256 above = i > targetPerBlock() ? i - targetPerBlock() : 0;
      assertEq(fee, computeFee(excess + above), "unexpected fee");
      addFailedRequest(sender(i), makeRequest(i), fee-1);
      addRequest(sender(i), makeRequest(i), fee);
      assertStorage(excess_slot, excess, "unexpected excess");
    }

    vm.roll(block.number + 1);
    assertEq(getCurrentFee(), computeFee(2 * excess), "unexpected fee");
  }

  // --------------------------------------------------------------------------
  // queue and system call ----------------------------------------------------
  // --------------------------------------------------------------------------

  // testQueueBeforeFork adds requests for several blocks with no system call,
  // as before the fork that starts it. The fee stays at the minimum at the
  // target rate, and the first system calls then return the requests in order,
  // the maximum per block at a time.
  function testQueueBeforeFork() public {
    uint256 blocks = maxPerBlock() / targetPerBlock() + 1;
    uint256 count = 0;
    for (uint256 b = 0; b < blocks; b++) {
      for (uint256 i = 0; i < targetPerBlock(); i++) {
        assertEq(getCurrentFee(), 1, "unexpected fee at the target rate");
        addRequest(sender(count), makeRequest(count), 1);
        count++;
      }
      vm.roll(block.number + 1);
    }
    assertStorage(queue_head_slot, 0, "unexpected head");
    assertStorage(queue_tail_slot, count, "unexpected tail");
    assertStorage(excess_slot, 0, "unexpected excess");

    // The first system call reads a full block from cold storage, within its
    // gas limit.
    vm.cool(addr);
    vm.prank(sysaddr);
    (bool ret, bytes memory out) = addr.call{gas: system_call_gas_limit}("");
    emit log_named_uint("system call gas, full block", vm.lastCallGas().gasTotalUsed);
    assertEq(ret, true);
    checkRecords(out, 0, maxPerBlock());
    assertStorage(queue_head_slot, maxPerBlock(), "unexpected head");
    assertStorage(queue_tail_slot, count, "unexpected tail");

    // The system call leaves the fee state alone.
    assertStorage(excess_slot, 0, "unexpected excess");
    assertStorage(count_slot, targetPerBlock(), "unexpected request count");
    assertStorage(last_block_slot, block.number - 1, "unexpected last block");

    // The second one reads the rest and resets the queue.
    checkRecords(getRequests(), maxPerBlock(), count - maxPerBlock());
    assertStorage(queue_head_slot, 0, "expected queue head reset");
    assertStorage(queue_tail_slot, 0, "expected queue tail reset");
    assertEq(getRequests().length, 0, "expected an empty queue");

    // New requests go to the start of the queue again.
    addRequest(sender(count), makeRequest(count), 1);
    checkRecords(getRequests(), count, 1);
  }

  // testSystemCallWithInput verifies that a system call with input drains the
  // queue and sets the inhibitor to prevent further additions, and that a
  // system call with no input re-enables the queue with a fresh fee state.
  function testSystemCallWithInput() public {
    fillBlock(0);
    vm.roll(block.number + 1);
    addRequest(sender(0), makeRequest(0), getCurrentFee());
    assertGt(load(excess_slot), 0, "expected some excess");

    // Disable the queue with a system call that carries input data.
    vm.prank(sysaddr);
    (bool ret, bytes memory data) = addr.call(hex"01");
    assertEq(ret, true);
    assertEq(data.length, min(maxAddsPerBlock() + 1, maxPerBlock()) * recordSize(), "system call should drain the queue");
    assertStorage(excess_slot, inhibitor, "expected inhibitor in excess storage slot");

    // Check that requesting the current fee fails.
    (ret,) = addr.staticcall("");
    assertEq(ret, false, "expected fee getter to fail");

    // Check that adding a request fails.
    addFailedRequest(address(this), makeRequest(1), 1 ether);

    // A system call with input keeps the queue disabled.
    vm.prank(sysaddr);
    (ret,) = addr.call(hex"01");
    assertEq(ret, true);
    assertStorage(excess_slot, inhibitor, "expected inhibitor in excess storage slot");

    // Now re-enable the queue through a system call with no input.
    getRequests();
    assertStorage(excess_slot, 0, "expected zero excess requests after re-enabling queue");
    assertStorage(count_slot, 0, "expected zero request count after re-enabling queue");

    // Check that adding a request succeeds again with fee 1.
    assertEq(getCurrentFee(), 1, "unexpected fee");
    addRequest(address(this), makeRequest(2), 1);
  }

  // --------------------------------------------------------------------------
  // fee and queue from any state ---------------------------------------------
  // --------------------------------------------------------------------------
  //
  // These tests set the storage directly and compare the contract with the
  // rules of EIP-8483, which expectedFeeState and the tests state again.

  // testFuzzFee checks the fee getter from any fee state.
  function testFuzzFee(uint256 excess, uint256 count, uint256 elapsed, uint256 number) public {
    setFeeState(excess, count, elapsed, number);
    (,, uint256 fee) = expectedFeeState();
    assertEq(getCurrentFee(), fee, "unexpected fee");
  }

  // testFuzzAdd adds a request from any fee state and queue tail, from any
  // sender and with any value. The request is accepted if it pays the fee and
  // the block isn't full, and then it stores the fee state of the current
  // block. A rejected request changes nothing.
  function testFuzzAdd(uint256 excess, uint256 count, uint256 elapsed, uint256 number, uint256 tail, address from, uint256 value, uint256 x) public {
    // The system address would take the system call path, and the contract
    // can't be the sender because the test sets the sender's balance.
    vm.assume(from != sysaddr && from != addr);
    setFeeState(excess, count, elapsed, number);
    tail = bound(tail, 0, type(uint64).max);
    vm.store(addr, bytes32(queue_tail_slot), bytes32(tail));

    (uint256 newExcess, uint256 newCount, uint256 fee) = expectedFeeState();
    value = bound(value, 0, 2*fee + 1);
    bool accepted = value >= fee && newCount < maxAddsPerBlock();

    uint256[5] memory header;
    for (uint256 slot = 0; slot < pq_queue_storage_offset; slot++) {
      header[slot] = load(slot);
    }
    bytes memory req = makeRequest(x);
    vm.deal(from, value);
    vm.prank(from);
    (bool ret,) = addr.call{value: value}(req);
    assertEq(ret, accepted, "unexpected result");

    if (!accepted) {
      for (uint256 slot = 0; slot < pq_queue_storage_offset; slot++) {
        assertStorage(slot, header[slot], "a rejected request changed the storage");
      }
      assertEq(addr.balance, 0, "a rejected request paid");
      return;
    }
    assertStorage(excess_slot, newExcess, "unexpected excess");
    assertStorage(count_slot, newCount+1, "unexpected request count");
    assertStorage(last_block_slot, block.number, "unexpected last block");
    assertStorage(queue_head_slot, header[queue_head_slot], "unexpected head");
    assertStorage(queue_tail_slot, tail+1, "unexpected tail");
    assertQueued(tail, from, req);
    assertEq(addr.balance, value, "the contract keeps the value");
  }

  // testFuzzSystemCall runs the system call from any queue head, length and
  // contents, any fee state, and with or without input. It returns the
  // records of up to the maximum per block, in order, and moves the head, or
  // resets the queue when it empties it. It doesn't touch the fee state,
  // except for the inhibitor: input sets it, and no input clears it and
  // starts the fee state again.
  function testFuzzSystemCall(uint256 head, uint256 len, uint256 excess, uint256 count, uint256 last, bytes32 seed, bool inhibited, bool withInput) public {
    // Most queues are short, and some are longer than a block takes.
    head = bound(head, 0, type(uint64).max);
    len = bound(len, 0, len % 8 == 0 ? maxPerBlock() + 40 : 40);
    excess = inhibited ? inhibitor : bound(excess, 0, type(uint64).max);
    vm.store(addr, bytes32(excess_slot), bytes32(excess));
    vm.store(addr, bytes32(count_slot), bytes32(count));
    vm.store(addr, bytes32(queue_head_slot), bytes32(head));
    vm.store(addr, bytes32(queue_tail_slot), bytes32(head + len));
    vm.store(addr, bytes32(last_block_slot), bytes32(last));

    // Fill the items the call reads with any words, and build the records
    // they make: the low 20 bytes of the first slot, then the other slots up
    // to the size of the input.
    uint256 n = min(len, maxPerBlock());
    bytes memory expected = new bytes(n*recordSize() + 32);
    for (uint256 i = 0; i < n; i++) {
      uint256 idx = pq_queue_storage_offset + (head+i)*slotsPerItem();
      uint256 ost = i*recordSize();
      for (uint256 k = 0; k < slotsPerItem(); k++) {
        uint256 word = uint256(keccak256(abi.encode(seed, i, k)));
        vm.store(addr, bytes32(idx+k), bytes32(word));
        if (k == 0) {
          word = word << 96;
        }
        // A word written past the end of a record is overwritten by the
        // next record, or cut off below.
        assembly {
          mstore(add(add(expected, 32), ost), word)
        }
        ost += k == 0 ? 20 : 32;
      }
    }
    uint256 size = n*recordSize();
    assembly {
      mstore(expected, size)
    }

    vm.prank(sysaddr);
    (bool ret, bytes memory out) = addr.call{gas: system_call_gas_limit}(withInput ? bytes(hex"01") : bytes(""));
    assertEq(ret, true, "system call failed");
    assertEq(keccak256(out), keccak256(expected), "unexpected records");

    if (n == len) {
      assertStorage(queue_head_slot, 0, "expected queue head reset");
      assertStorage(queue_tail_slot, 0, "expected queue tail reset");
    } else {
      assertStorage(queue_head_slot, head + n, "unexpected head");
      assertStorage(queue_tail_slot, head + len, "unexpected tail");
    }
    if (withInput) {
      assertStorage(excess_slot, inhibitor, "expected inhibitor in excess storage slot");
      assertStorage(count_slot, count, "unexpected request count");
    } else if (inhibited) {
      assertStorage(excess_slot, 0, "expected zero excess after re-enabling queue");
      assertStorage(count_slot, 0, "expected zero request count after re-enabling queue");
    } else {
      assertStorage(excess_slot, excess, "the system call changed the excess");
      assertStorage(count_slot, count, "the system call changed the request count");
    }
    assertStorage(last_block_slot, last, "the system call changed the last block");
  }

  // --------------------------------------------------------------------------
  // helpers ------------------------------------------------------------------
  // --------------------------------------------------------------------------

  // setFeeState sets the block number and the three slots of the fee state:
  // the excess, the count of requests of the last block that had any, and
  // that block's number, which is elapsed blocks before the current one.
  function setFeeState(uint256 excess, uint256 count, uint256 elapsed, uint256 number) internal {
    // The excess of a few full blocks decays to zero in about as many blocks
    // as elapsed can be, so the tests see it decay partly and fully. One state
    // in four is in the block of the last request, and one in four has that
    // block full or one request short, so the limit per block is hit often.
    excess = bound(excess, 0, 4*maxAddsPerBlock());
    count = count % 4 == 0 ? maxAddsPerBlock() - (count / 4) % 2 : bound(count, 0, maxAddsPerBlock());
    elapsed = elapsed % 4 == 1 ? 0 : bound(elapsed, 0, 6*maxAddsPerBlock()/targetPerBlock());
    number = bound(number, elapsed, type(uint64).max);
    vm.roll(number);
    vm.store(addr, bytes32(excess_slot), bytes32(excess));
    vm.store(addr, bytes32(count_slot), bytes32(count));
    vm.store(addr, bytes32(last_block_slot), bytes32(number - elapsed));
  }

  // expectedFeeState computes, from the fee state in storage, what EIP-8483
  // specifies for the current block: the excess, the count of requests added
  // in it, and the fee of the next request.
  //
  // If no request was added in this block yet, the count of the last block
  // that had requests is added to the excess, which then decays by the target
  // for every block since. The fee also counts the requests of this block
  // above the target.
  function expectedFeeState() internal returns (uint256 excess, uint256 count, uint256 fee) {
    excess = load(excess_slot);
    count = load(count_slot);
    uint256 last = load(last_block_slot);
    if (block.number != last) {
      uint256 decay = targetPerBlock() * (block.number - last);
      excess = excess + count > decay ? excess + count - decay : 0;
      count = 0;
    }
    fee = computeFee(count > targetPerBlock() ? excess + count - targetPerBlock() : excess);
  }

  // addRequest submits a request to the system contract, expects it to succeed
  // and checks what it wrote.
  function addRequest(address from, bytes memory req, uint256 value) internal {
    // Load the fee state and the tail index before adding the request.
    uint256 count = load(last_block_slot) == block.number ? load(count_slot) : 0;
    uint256 tail = load(queue_tail_slot);

    // Send request from address.
    vm.deal(from, value);
    vm.prank(from);
    (bool ret,) = addr.call{value: value}(req);
    assertEq(ret, true, "expected call to succeed");

    // Verify the fee state and the queue data were updated correctly.
    assertStorage(count_slot, count+1, "unexpected request count");
    assertStorage(last_block_slot, block.number, "unexpected last block");
    assertStorage(queue_tail_slot, tail+1, "unexpected tail slot");

    assertQueued(tail, from, req);
  }

  // assertQueued verifies that a request is in the queue at the given index:
  // the address, then the input in 32-byte words, the last one padded with
  // zeros.
  function assertQueued(uint256 index, address from, bytes memory req) internal view {
    uint256 idx = pq_queue_storage_offset+index*slotsPerItem();
    assertStorage(idx, uint256(uint160(from)), "addr not written to queue");
    for (uint256 k = 1; k < slotsPerItem(); k++) {
      uint256 start = (k-1)*32;
      assertStorage(idx+k, toFixed(req, start, min(start+32, inputSize())), "input not written to queue");
    }
  }

  // fillBlock adds the maximum of requests that fit in the current block,
  // starting at the given request index.
  function fillBlock(uint256 start) internal {
    for (uint256 i = start; i < start + maxAddsPerBlock(); i++) {
      addRequest(sender(i), makeRequest(i), getCurrentFee());
    }
  }

  // checkRecords verifies that a system call's output holds count records,
  // those of the requests from startIndex on.
  //
  // It assumes that request i was added by sender(i) with makeRequest(i).
  function checkRecords(bytes memory out, uint256 startIndex, uint256 count) internal view {
    assertEq(out.length, count*recordSize());
    for (uint256 i = 0; i < count; i++) {
      bytes memory record = makeRecord(sender(startIndex+i), makeRequest(startIndex+i));
      assertEq(keccak256(slice(out, i*recordSize(), recordSize())), keccak256(record), "unexpected record returned");
    }
  }

  // sender returns the address that adds request x.
  function sender(uint256 x) internal pure returns (address) {
    return address(uint160(0x10000 + x));
  }

  // makeRequest returns the request (pubkey ++ pq_data ++ proof) of one of the
  // three valid proofs.
  function makeRequest(uint256 x) internal view returns (bytes memory) {
    return requests[x % 3];
  }

  // makeRequestAt builds the request of the proof at the given key of the
  // vectors file. pq_data is the leanXMSS public key. For validators, 32 bytes
  // follow it, which the proof doesn't sign.
  function makeRequestAt(string memory key) internal view returns (bytes memory) {
    bytes memory pk = vm.parseJsonBytes(vectors, string.concat(key, ".blsPubkey"));
    bytes32 xmss = vm.parseJsonBytes32(vectors, string.concat(key, ".xmssPubkey"));
    bytes memory proof = vm.parseJsonBytes(vectors, string.concat(key, ".signature"));
    assertEq(pk.length, pubkey_size);
    assertEq(proof.length, proof_size);

    bytes memory data = abi.encodePacked(xmss);
    if (pqDataSize() == 64) {
      data = abi.encodePacked(xmss, keccak256(abi.encodePacked("vrf", xmss)));
    }
    return bytes.concat(pk, data, proof);
  }

  // makeRecord returns the record of a request: source_address ++ input.
  function makeRecord(address from, bytes memory req) internal pure returns (bytes memory) {
    return abi.encodePacked(from, slice(req, 0, inputSize()));
  }

  // flip returns a copy of data with the lowest bit of the byte at idx changed.
  function flip(bytes memory data, uint256 idx) internal pure returns (bytes memory out) {
    out = bytes.concat(data);
    out[idx] = out[idx] ^ 0x01;
  }

  // splice returns a copy of data with len bytes at start replaced by the same
  // bytes of other.
  function splice(bytes memory data, bytes memory other, uint256 start, uint256 len) internal pure returns (bytes memory out) {
    out = bytes.concat(data);
    for (uint256 i = start; i < start+len; i++) {
      out[i] = other[i];
    }
  }

  // startsWithOne returns a copy of req whose first 32 bytes are the word 1.
  function startsWithOne(bytes memory req) internal pure returns (bytes memory out) {
    out = bytes.concat(req);
    assembly {
      mstore(add(out, 32), 1)
    }
  }

  // hashVerifier returns the code of a verifier that returns 1 if the hash of
  // its calldata is the given one, and 0 otherwise:
  //
  //   calldatacopy(0, 0, calldatasize)
  //   mstore(0, keccak256(0, calldatasize) == hash)
  //   return(0, 32)
  function hashVerifier(bytes32 hash) internal pure returns (bytes memory) {
    return abi.encodePacked(hex"365f5f37365f207f", hash, hex"145f5260205ff3");
  }

  // deploy runs init code and returns the address of the created contract.
  function deploy(bytes memory code) internal returns (address deployed) {
    assembly {
      deployed := create(0, add(code, 32), mload(code))
    }
    assertTrue(deployed != address(0), "deployment failed");
  }

  // readHex reads a file with hex-encoded bytes.
  function readHex(string memory path) internal view returns (bytes memory) {
    return vm.parseBytes(vm.readFile(path));
  }

  // getCurrentFee returns the current fee computed by the system contract.
  function getCurrentFee() internal view returns (uint256) {
    (bool ok, bytes memory data) = addr.staticcall("");
    assert(ok);
    return uint256(bytes32(data));
  }
}

contract PQValidatorRegistrationTest is PQRegistrationTest {
  function bytecodeDir() internal pure override returns (string memory) {
    return "pq_registrations";
  }

  function pqDataSize() internal pure override returns (uint256) {
    return 64;
  }

  function targetPerBlock() internal pure override returns (uint256) {
    return 128;
  }

  function maxAddsPerBlock() internal pure override returns (uint256) {
    return 256;
  }

  function maxPerBlock() internal pure override returns (uint256) {
    return 1024;
  }

  // testUnsignedData checks that the proof doesn't sign the second half of
  // pq_data: a request with other bytes there is accepted, and stored as sent.
  function testUnsignedData() public {
    bytes memory req = makeRequest(0);
    for (uint256 ost = signed_size; ost < inputSize(); ost += 31) {
      req = flip(req, ost);
    }
    addRequest(address(this), req, 1);
    assertEq(getRequests(), makeRecord(address(this), req), "unexpected record");
  }

  // testProofForBothContracts checks that one proof registers a leanXMSS key
  // in both contracts. The proof signs the BLS key and the leanXMSS key, and
  // not which contract it is for, so a validator and a builder that share a
  // BLS key share the proof.
  function testProofForBothContracts() public {
    address builders = 0x000000000000000000000000000000000000CcCc;
    vm.etch(builders, readHex("bytecode/pq_builder_registrations/main.hex"));

    bytes memory req = makeRequest(0);
    addRequest(address(this), req, 1);

    // The builder request has no data between the leanXMSS key and the proof.
    bytes memory builderReq = bytes.concat(slice(req, 0, signed_size), slice(req, inputSize(), proof_size));
    vm.deal(address(this), 1);
    (bool ret,) = builders.call{value: 1}(builderReq);
    assertEq(ret, true, "expected the builder request to succeed");

    // A validator request is not a builder request.
    vm.deal(address(this), 1);
    (ret,) = builders.call{value: 1}(req);
    assertEq(ret, false, "expected the validator request to fail");
  }
}

contract PQBuilderRegistrationTest is PQRegistrationTest {
  function bytecodeDir() internal pure override returns (string memory) {
    return "pq_builder_registrations";
  }

  function pqDataSize() internal pure override returns (uint256) {
    return 32;
  }

  function targetPerBlock() internal pure override returns (uint256) {
    return 2;
  }

  function maxAddsPerBlock() internal pure override returns (uint256) {
    return 16;
  }

  function maxPerBlock() internal pure override returns (uint256) {
    return 16;
  }
}
