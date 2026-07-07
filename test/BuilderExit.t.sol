// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./Test.sol";

uint256 constant target_per_block = 2;
uint256 constant max_per_block = 16;
uint256 constant inhibitor = uint256(bytes32(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff));

uint256 constant slots_per_item = 3;

contract BuilderExitTest is Test {
  function setUp() public {
    vm.etch(addr, vm.parseBytes(vm.readFile("bytecode/builder_exits/main.hex")));
    vm.etch(fakeExpo, vm.parseBytes(vm.readFile("bytecode/fake_expo_test/main.hex")));
  }

  // testInvalidExit checks that common invalid exit requests are rejected.
  function testInvalidExit() public {
    bytes memory pk = makeExit(0);

    // pubkey too small
    (bool ret,) = addr.call{value: 1}(hex"1234");
    assertEq(ret, false);

    // pubkey one byte short (47 bytes)
    (ret,) = addr.call{value: 1}(slice(pk, 0, 47));
    assertEq(ret, false);

    // pubkey one byte long (49 bytes)
    (ret,) = addr.call{value: 1}(bytes.concat(pk, hex"00"));
    assertEq(ret, false);

    // ABI-style call (4-byte selector prefix)
    (ret,) = addr.call{value: 1}(bytes.concat(hex"deadbeef", pk));
    assertEq(ret, false);

    // fee too small
    (ret,) = addr.call{value: 0}(pk);
    assertEq(ret, false);

    assertStorage(count_slot, 0, "expected no requests enqueued");
  }

  // testExit verifies a single exit request below the target request count is
  // accepted and read successfully.
  function testExit() public {
    bytes memory pk = makeExit(1);
    bytes memory record = abi.encodePacked(address(this), pk); // source_address ++ pubkey

    vm.expectEmitAnonymous(false, false, false, false, true);
    assembly {
      log0(add(record, 32), mload(record))
    }

    vm.deal(address(this), 1);
    (bool ret,) = addr.call{value: 1}(pk);
    assertEq(ret, true);
    assertStorage(count_slot, 1, "unexpected request count");
    assertExcess(0);

    bytes memory req = getRequests();
    assertEq(req.length, 68);
    assertEq(req, record, "unexpected record");
    assertStorage(count_slot, 0, "unexpected request count");
    assertStorage(queue_head_slot, 0, "expected queue head reset");
    assertStorage(queue_tail_slot, 0, "expected queue tail reset");
    assertExcess(0);
  }

  // testExitRecordsCaller verifies the recorded source_address is the caller,
  // the field the consensus layer checks against the builder's execution_address.
  function testExitRecordsCaller() public {
    address caller = 0xCAfEcAfeCAfECaFeCaFecaFecaFECafECafeCaFe;
    bytes memory pk = makeExit(0xCD);

    vm.deal(caller, 1);
    vm.prank(caller);
    (bool ret,) = addr.call{value: 1}(pk);
    assertEq(ret, true);

    bytes memory req = getRequests();
    assertEq(address(bytes20(slice(req, 0, 20))), caller, "source_address must be the caller");
    assertEq(slice(req, 20, 48), pk, "unexpected pubkey");
  }

  // testQueueReset verifies that after a period of time where there are more
  // request than can be read per block, the queue is eventually cleared and the
  // head and tails are reset to zero.
  function testQueueReset() public {
    // Add more exit requests than the max per block (16) so that the queue is
    // not immediately emptied.
    for (uint256 i = 0; i < max_per_block+1; i++) {
      uint256 fee = getCurrentFee();
      addRequest(address(uint160(i)), makeExit(i), fee);
    }
    assertStorage(count_slot, max_per_block+1, "unexpected request count");

    // Simulate syscall, check that max exit requests per block are read.
    checkExits(0, max_per_block);
    assertExcess(15);

    // Add another batch of max exit requests per block (16) so the next read
    // leaves a single exit request in the queue.
    for (uint256 i = 17; i < 33; i++) {
      uint256 fee = getCurrentFee();
      addRequest(address(uint160(i)), makeExit(i), fee);
    }
    assertStorage(count_slot, max_per_block, "unexpected request count");

    // Simulate syscall. Verify first that max per block are read. Then
    // verify only the single final request is read.
    checkExits(16, max_per_block);
    assertExcess(29);
    checkExits(32, 1);
    assertExcess(27);

    // Now ensure the queue is empty and has reset to zero.
    assertStorage(queue_head_slot, 0, "expected queue head reset");
    assertStorage(queue_tail_slot, 0, "expected queue tail reset");

    // Add five (5) more requests to check that new requests can be added after
    // the queue is reset.
    for (uint256 i = 33; i < 38; i++) {
      uint256 fee = getCurrentFee();
      addRequest(address(uint160(i)), makeExit(i), fee);
    }
    assertStorage(count_slot, 5, "unexpected request count");

    // Simulate syscall, read only the max requests per block.
    checkExits(33, 5);
    assertExcess(30);
  }

  // testFee adds many requests, and verifies the fee decreases correctly until
  // it returns to 0.
  function testFee() public {
    uint256 idx = 0;
    uint256 count = max_per_block*64;

    // Add a bunch of requests.
    for (; idx < count; idx++) {
      uint256 fee = getCurrentFee();
      if (idx < target_per_block) {
        assertEq(fee, 1, "unexpected fee for request below excess");
      } else {
        assertEq(fee, computeFee(idx - target_per_block), "unexpected fee");
      }
      addRequest(address(uint160(idx)), makeExit(idx), fee);
    }
    assertStorage(count_slot, count, "unexpected request count");
    checkExits(0, max_per_block);

    uint256 read = max_per_block;
    uint256 excess = count - target_per_block;

    // Attempt to add a deposit request one wei short of the stake plus fee and a
    // deposit request with exactly stake plus fee. This should cause the excess
    // requests counter to decrease until it returns to 0.
    while (excess != 0) {
      assertExcess(excess);

      uint256 fee = computeFee(excess);
      addFailedRequest(address(uint160(idx)), makeExit(idx), fee-1);
      addRequest(address(uint160(idx)), makeExit(idx), fee);

      uint256 expected = min(idx-read+1, max_per_block);
      checkExits(read, expected);

      if (excess + 1 > target_per_block) {
        excess = excess + 1 - target_per_block;
      } else {
        excess = 0;
      }
      read += expected;
      idx++;
    }
  }

  // testFeePerTx checks how fees are computed within a single block.
  function testFeePerTx() public {
    // first requests have a fee of 1
    uint256 idx = 0;
    for (; idx <= target_per_block+12; idx++) {
      addRequest(address(uint160(idx)), makeExit(idx), 1);
    }
    assertStorage(count_slot, idx, "unexpected request count in storage");

    // now fee rises. Here we just run it until the fee exceeds 100 gwei.
    uint256 prevFee = 1;
    while (true) {
        uint256 fee = getCurrentFee();
        if (fee >= 100 gwei) {
            break;
        }
        assertGe(fee, prevFee, "fee did not rise");
        addRequest(address(uint160(idx)), makeExit(idx), fee);
        idx++;
    }

    assertEq(idx, 433, "unexpected request count");
    assertStorage(count_slot, idx, "unexpected request count in storage");
  }

  // testFeeGetterRejectsValue verifies the empty-calldata fee getter reverts
  // when value is attached, preventing accidentally lost funds.
  function testFeeGetterRejectsValue() public {
    vm.deal(address(this), 1);
    (bool ret,) = addr.call{value: 1}("");
    assertEq(ret, false, "fee getter must reject callvalue");
  }

    // testSystemCallWithInput verifies that a system call with input drains the queue, and
  // sets the inhibitor to prevent further additions.
  function testSystemCallWithInput() public {
    addRequest(address(this), makeExit(1), 1);

    // Disable the queue with a system call that carries input data.
    vm.prank(sysaddr);
    (bool ret, bytes memory data) = addr.call(hex"01");
    assertEq(ret, true);
    assertEq(data.length, 68, "system call should drain the queue");
    assertStorage(excess_slot, inhibitor, "expected inhibitor in excess storage slot");

    // Check that requesting the current fee fails.
    (ret,) = addr.staticcall("");
    assertEq(ret, false, "expected fee getter to fail");

    // Check that adding a request fails.
    addFailedRequest(address(this), makeExit(2), 1);

    // Now re-enable the queue through a system call with no input.
    vm.prank(sysaddr);
    (ret, data) = addr.call("");
    assertEq(ret, true);
    assertEq(data.length, 0, "system call should return empty data since there are no requests");
    assertStorage(excess_slot, 0, "expected zero excess requests after re-enabling queue");

    // Check that adding a requests succeeds again.
    addRequest(address(this), makeExit(3), 1);
  }

  // testQueueDisableFeeReset verifies that re-enabling the queue resets the fee to 1.
  function testQueueDisableFeeReset() public {
    uint256 requestCount = max_per_block*4;
    for (uint64 i = 0; i < requestCount; i++) {
      uint256 fee = getCurrentFee();
      addRequest(address(this), makeExit(uint256(i)), fee);
    }
    assertStorage(count_slot, requestCount, "unexpected request count");

    // Disable the queue with a system call that carries input data.
    vm.prank(sysaddr);
    (bool ret, bytes memory data) = addr.call(hex"01");
    assertEq(ret, true);
    assertEq(data.length, max_per_block*68, "system call should drain the queue");
    assertStorage(excess_slot, inhibitor, "expected inhibitor in excess storage slot");

    // Now re-enable the queue through a system call with no input.
    vm.prank(sysaddr);
    (ret, data) = addr.call("");
    assertEq(ret, true);
    assertEq(data.length, max_per_block*68, "system call should drain the queue");
    assertStorage(excess_slot, 0, "expected zero excess requests after re-enabling queue");

    // Check that adding a requests succeeds again with fee 1.
    addRequest(address(this), makeExit(999), 1);
  }

  // --------------------------------------------------------------------------
  // helpers ------------------------------------------------------------------
  // --------------------------------------------------------------------------

  // addRequest will submit an exit request to the system contract with the given
  // values.
  function addRequest(address from, bytes memory req, uint256 value) internal {
    // Load tail index before adding request.
    uint256 requests = load(count_slot);
    uint256 tail = load(queue_tail_slot);

    // Send request from address.
    vm.deal(from, value);
    vm.prank(from);
    (bool ret,) = addr.call{value: value}(req);
    assertEq(ret, true, "expected call to succeed");

    // Verify the queue data was updated correctly.
    assertStorage(count_slot, requests+1, "unexpected request count");
    assertStorage(queue_tail_slot, tail+1, "unexpected tail slot");

    // Verify the request was written to the queue.
    uint256 idx = queue_storage_offset+tail*slots_per_item;
    assertStorage(idx, uint256(uint160(from)), "addr not written to queue");
    assertStorage(idx+1, toFixed(req, 0, 32), "pk[0:32] not written to queue");
    assertStorage(idx+2, toFixed(req, 32, 48), "pk[32:48] not written to queue");
  }

  // checkExits will simulate a system call to the system contract and verify the
  // expected exit requests are returned.
  //
  // It assumes that addresses are stored as uint256(index) and pubkeys are
  // uint8(index), repeating.
  function checkExits(uint256 startIndex, uint256 count) internal returns (uint256) {
    bytes memory requests = getRequests();
    assertEq(requests.length, count*68);

    for (uint256 i = 0; i < count; i++) {
      uint256 offset = i*68;
      bytes memory pk = makeExit(startIndex+i);

      // Check address, pubkey.
      assertEq(toFixed(requests, offset, offset+20) >> 96, uint256(startIndex+i), "unexpected request address returned");
      assertEq(toFixed(requests, offset+20, offset+52), toFixed(pk, 0, 32), "unexpected request pk1 returned");
      assertEq(toFixed(requests, offset+52, offset+68), toFixed(pk, 32, 48), "unexpected request pk2 returned");
    }

    return count;
  }

  // makeExit constructs an exit request (a bare pubkey) with a base of x.
  function makeExit(uint256 x) internal pure returns (bytes memory) {
    bytes memory pk = new bytes(48);
    for (uint256 i = 0; i < 48; i++) {
      pk[i] = bytes1(uint8(x));
    }
    return pk;
  }

  // getCurrentFee returns the current fee computed by the system contract.
  function getCurrentFee() internal view returns(uint256) {
    (bool ok, bytes memory data) = addr.staticcall("");
    assert(ok);
    return uint256(bytes32(data));
  }
}
