// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./Test.sol";

uint256 constant target_per_block = 32;
uint256 constant max_per_block = 256;
uint256 constant inhibitor = uint256(bytes32(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff));

uint256 constant min_amount = 1000000000; // minimum deposit amount in gwei (1 ETH)
uint256 constant slots_per_item = 6;

contract BuilderDepositTest is Test {
  function setUp() public {
    vm.etch(addr, vm.parseBytes(vm.readFile("bytecode/builder_deposits/main.hex")));
    vm.etch(fakeExpo, vm.parseBytes(vm.readFile("bytecode/fake_expo_test/main.hex")));
  }

  // testInvalidDeposit checks that common invalid deposit requests are rejected.
  function testInvalidDeposit() public {
    bytes memory req = makeDeposit(0);
    uint256 value = min_amount * 1 gwei + 1; // stake + fee (fee is 1 at excess 0)

    // input too small
    (bool ret,) = addr.call{value: value}(hex"1234");
    assertEq(ret, false);

    // input one byte short (183 bytes)
    (ret,) = addr.call{value: value}(slice(req, 0, 183));
    assertEq(ret, false);

    // input one byte long (185 bytes)
    (ret,) = addr.call{value: value}(bytes.concat(req, hex"00"));
    assertEq(ret, false);

    // ABI-style call (4-byte selector prefix)
    (ret,) = addr.call{value: value}(bytes.concat(hex"deadbeef", req));
    assertEq(ret, false);

    // fee too small
    (ret,) = addr.call{value: 0}(req);
    assertEq(ret, false);

    // amount below the minimum
    (ret,) = addr.call{value: value}(makeDepositAmount(0, uint64(min_amount-1)));
    assertEq(ret, false);

    // value covers the stake but leaves nothing for the fee
    (ret,) = addr.call{value: min_amount * 1 gwei}(req);
    assertEq(ret, false);

    assertStorage(count_slot, 0, "expected no requests enqueued");
  }

  // testDeposit verifies a single deposit request below the target request count
  // is accepted and read successfully, with the amount converted to
  // little-endian on the read path.
  function testDeposit() public {
    uint64 amount = 0x0102030405060708;
    bytes memory data    = makeDepositAmount(1, amount);
    bytes memory exp_req = toRecord(data); // input with the amount byte-reversed
    uint256 value = uint256(amount) * 1 gwei + computeFee(0);
    vm.deal(address(this), value);

    // The accepted input is emitted verbatim as an anonymous log (the amount
    // big-endian, as submitted).
    vm.expectEmitAnonymous(false, false, false, false, true);
    assembly {
      log0(add(data, 32), mload(data))
    }

    (bool ret,) = addr.call{value: value}(data);
    assertEq(ret, true);
    assertStorage(count_slot, 1, "unexpected request count");
    assertExcess(0);

    bytes memory req = getRequests();
    assertEq(req.length, 184);
    assertEq(req, exp_req, "unexpected record");
    assertEq(slice(req, 80, 8), hex"0807060504030201", "amount not little-endian");
    assertStorage(count_slot, 0, "unexpected request count");
    assertStorage(queue_head_slot, 0, "expected queue head reset");
    assertStorage(queue_tail_slot, 0, "expected queue tail reset");
    assertExcess(0);
  }

  // testQueueReset verifies that after a period of time where there are more
  // request than can be read per block, the queue is eventually cleared and the
  // head and tails are reset to zero.
  function testQueueReset() public {
    // Add more deposit requests than the max per block so that the queue is not
    // immediately emptied.
    for (uint256 i = 0; i < max_per_block+1; i++) {
      uint256 fee = getCurrentFee();
      addRequest(address(uint160(i)), makeDeposit(i), min_amount * 1 gwei + fee);
    }
    assertStorage(count_slot, max_per_block+1, "unexpected request count");

    // Simulate syscall, check that max deposit requests per block are read.
    checkDeposits(0, max_per_block);
    assertExcess(max_per_block + 1 - target_per_block);

    // Add another batch of max deposit requests per block so the next read
    // leaves a single deposit request in the queue.
    for (uint256 i = max_per_block+1; i < 2*max_per_block+1; i++) {
      uint256 fee = getCurrentFee();
      addRequest(address(uint160(i)), makeDeposit(i), min_amount * 1 gwei + fee);
    }
    assertStorage(count_slot, max_per_block, "unexpected request count");

    // Simulate syscall. Verify first that max per block are read. Then
    // verify only the single final request is read.
    checkDeposits(max_per_block, max_per_block);
    assertExcess(2*max_per_block - 2*target_per_block + 1);
    checkDeposits(2*max_per_block, 1);
    assertExcess(2*max_per_block - 3*target_per_block + 1);

    // Now ensure the queue is empty and has reset to zero.
    assertStorage(queue_head_slot, 0, "expected queue head reset");
    assertStorage(queue_tail_slot, 0, "expected queue tail reset");

    // Add five (5) more requests to check that new requests can be added after
    // the queue is reset.
    for (uint256 i = 2*max_per_block+1; i < 2*max_per_block+6; i++) {
      uint256 fee = getCurrentFee();
      addRequest(address(uint160(i)), makeDeposit(i), min_amount * 1 gwei + fee);
    }
    assertStorage(count_slot, 5, "unexpected request count");

    // Simulate syscall, read only the max requests per block.
    checkDeposits(2*max_per_block+1, 5);
    assertExcess(2*max_per_block - 4*target_per_block + 6);
  }

  // testFee adds many requests, and verifies the fee decreases correctly until
  // it returns to 0. At every step the value must cover the stake plus the fee.
  function testFee() public {
    uint256 idx = 0;
    uint256 count = max_per_block + target_per_block;

    // Add a bunch of requests.
    for (; idx < count; idx++) {
      uint256 fee = getCurrentFee();
      if (idx < target_per_block) {
        assertEq(fee, 1, "unexpected fee for request below excess");
      } else {
        assertEq(fee, computeFee(idx - target_per_block), "unexpected fee");
      }

      addRequest(address(uint160(idx)), makeDeposit(idx), min_amount * 1 gwei + fee);
    }
    assertStorage(count_slot, count, "unexpected request count");
    checkDeposits(0, max_per_block);

    uint256 read = max_per_block;
    uint256 excess = count - target_per_block;

    // Attempt to add a deposit request one wei short of the stake plus fee and a
    // deposit request with exactly stake plus fee. This should cause the excess
    // requests counter to decrease until it returns to 0.
    while (excess != 0) {
      assertExcess(excess);

      uint256 value = min_amount * 1 gwei + computeFee(excess);
      addFailedRequest(address(uint160(idx)), makeDeposit(idx), value-1);
      addRequest(address(uint160(idx)), makeDeposit(idx), value);

      uint256 expected = min(idx-read+1, max_per_block);
      checkDeposits(read, expected);

      if (excess + 1 > target_per_block) {
        excess = excess + 1 - target_per_block;
      } else {
        excess = 0;
      }
      read += expected;
      idx++;
    }
    assertExcess(0);
  }

  // testFeePerTx checks how fees are computed within a single block.
  function testFeePerTx() public {
    uint256 val = min_amount * 1 gwei;

    // first requests have a fee of 1
    uint256 idx = 0;
    for (; idx <= target_per_block+12; idx++) {
      addRequest(address(uint160(idx)), makeDeposit(idx), val + 1);
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
        addRequest(address(uint160(idx)), makeDeposit(idx), val + fee);
        idx++;
    }

    assertEq(idx, 463, "unexpected request count");
    assertStorage(count_slot, idx, "unexpected request count in storage");
  }

  // testFeeGetterRejectsValue verifies the empty-calldata fee getter reverts
  // when value is attached, preventing accidentally lost funds.
  function testFeeGetterRejectsValue() public {
    vm.deal(address(this), 1);
    (bool ret,) = addr.call{value: 1}("");
    assertEq(ret, false, "fee getter must reject callvalue");
  }

  // testSystemCallDrainsRegardlessOfCalldata verifies the system address caller
  // check precedes the calldata dispatch, so the queue drains on any calldata.
  function testSystemCallDrainsRegardlessOfCalldata() public {
    addRequest(address(this), makeDeposit(1), min_amount * 1 gwei + 1);

    vm.prank(sysaddr);
    (bool ret, bytes memory data) = addr.call(hex"01");
    assertEq(ret, true);
    assertEq(data.length, 184, "system call should drain the queue");
  }

  // --------------------------------------------------------------------------
  // helpers ------------------------------------------------------------------
  // --------------------------------------------------------------------------

  // addRequest will submit a deposit request to the system contract with the
  // given values.
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

    // Verify the request was written to the queue. The deposit record carries no
    // source address; the six slots hold the input verbatim (amount big-endian).
    uint256 idx = queue_storage_offset+tail*slots_per_item;
    assertStorage(idx,   toFixed(req, 0, 32),    "pk[0:32] not written to queue");
    assertStorage(idx+1, toFixed(req, 32, 64),   "pk[32:48] ++ wc[0:16] not written to queue");
    assertStorage(idx+2, toFixed(req, 64, 96),   "wc[16:32] ++ amount ++ sig[0:8] not written to queue");
    assertStorage(idx+3, toFixed(req, 96, 128),  "sig[8:40] not written to queue");
    assertStorage(idx+4, toFixed(req, 128, 160), "sig[40:72] not written to queue");
    assertStorage(idx+5, toFixed(req, 160, 184), "sig[72:96] not written to queue");
  }

  // checkDeposits will simulate a system call to the system contract and verify
  // the expected deposit requests are returned, each with the amount converted
  // to little-endian.
  //
  // It assumes requests were created with makeDeposit, i.e. pubkey,
  // withdrawal_credentials, and signature are all uint8(index) repeating and the
  // amount is the minimum.
  function checkDeposits(uint256 startIndex, uint256 count) internal returns (uint256) {
    bytes memory requests = getRequests();
    assertEq(requests.length, count*184);
    for (uint256 i = 0; i < count; i++) {
      uint256 offset = i*184;
      bytes memory exp_req = toRecord(makeDeposit(startIndex+i));
      assertEq(slice(requests, offset, 184), exp_req, "unexpected deposit record returned");
    }
    return count;
  }

  // makeDeposit constructs a deposit request with a base of x and the minimum
  // amount.
  function makeDeposit(uint256 x) internal pure returns (bytes memory) {
    return makeDepositAmount(x, uint64(min_amount));
  }

  // makeDepositAmount constructs a deposit request: pubkey (48) ++
  // withdrawal_credentials (32) ++ amount (8, big-endian) ++ signature (96). The
  // pubkey, credentials, and signature are all filled with uint8(x).
  function makeDepositAmount(uint256 x, uint64 amount) internal pure returns (bytes memory) {
    bytes memory pk = new bytes(48);
    for (uint256 i = 0; i < 48; i++) {
      pk[i] = bytes1(uint8(x));
    }
    bytes memory wc = new bytes(32);
    for (uint256 i = 0; i < 32; i++) {
      wc[i] = bytes1(uint8(x));
    }
    bytes memory sig = new bytes(96);
    for (uint256 i = 0; i < 96; i++) {
      sig[i] = bytes1(uint8(x));
    }
    bytes memory out = abi.encodePacked(pk, wc, bytes8(amount), sig);
    require(out.length == 184);
    return out;
  }

  // toRecord converts a deposit input into its dequeued record by reversing the
  // 8-byte amount (bytes 80:88) to little-endian; all other bytes are verbatim.
  function toRecord(bytes memory input) internal pure returns (bytes memory out) {
    out = bytes.concat(input);
    for (uint256 i = 0; i < 8; i++) {
      out[80+i] = input[87-i];
    }
  }

  // getCurrentFee returns the current fee computed by the system contract.
  function getCurrentFee() internal view returns(uint256) {
    (bool ok, bytes memory data) = addr.staticcall("");
    assert(ok);
    return uint256(bytes32(data));
  }
}
