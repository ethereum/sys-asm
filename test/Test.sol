// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test as StdTest} from "forge-std/Test.sol";

address constant fakeExpo = 0x000000000000000000000000000000000000BbBB;
address constant addr = 0x000000000000000000000000000000000000aaaa;
address constant sysaddr = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

uint256 constant excess_slot = 0;
uint256 constant count_slot = 1;
uint256 constant queue_head_slot = 2;
uint256 constant queue_tail_slot = 3;
uint256 constant queue_storage_offset = 4;

// Test has some helper functions used by multiple system contract test suites.
abstract contract Test is StdTest {
  // getRequests makes a call to the system contract as the system address in
  // order to trigger a dequeue action.
  function getRequests() internal returns (bytes memory) {
    vm.prank(sysaddr);
    (bool ret, bytes memory data) = addr.call("");
    assertEq(ret, true);
    return data;
  }

  // addFailedRequest submits a request to the system contract and expects it to
  // fail.
  function addFailedRequest(address from, bytes memory req, uint256 value) internal {
    vm.deal(from, value);
    vm.prank(from);
    (bool ret,) = addr.call{value: value}(req);
    assertEq(ret, false, "expected request to fail");
  }

  // load is a helper function to read a specific storage slot in the system
  // contract.
  function load(uint256 slot) internal view returns (uint256) {
    return uint256(vm.load(addr, bytes32(slot)));
  }

  // assertStorage reads a value from the system contract and asserts it is
  // equal to the provided value.
  function assertStorage(uint256 slot, uint256 value, string memory err) internal view {
    bytes32 got = vm.load(addr, bytes32(slot));
    assertEq(got, bytes32(value), err);
  }

  // assertExcess verifies the excess returned from storage and by calling the
  // system contract matches count.
  function assertExcess(uint256 count) internal {
    assertStorage(excess_slot, count, "unexpected excess requests");
    uint256 expectedFee = computeFee(count);
    (, bytes memory data) = addr.call("");
    assertEq(uint256(bytes32(data)), expectedFee, "unexpected fee returned");
  }
}

// min returns the minimum value of x and y.
function min(uint256 x, uint256 y) pure returns (uint256) {
  if (x < y) {
    return x;
  }
  return y;
}

// toFixed copys data from memory into a uint256. If the length is less than 32,
// the output is right-padded with zeros.
function toFixed(bytes memory data, uint256 start, uint256 end) pure returns (uint256) {
  require(end-start <= 32, "range cannot be larger than 32 bytes");
  bytes memory out = new bytes(32);
  for (uint256 i = start; i < end; i++) {
    out[i-start] = data[i];
  }
  return uint256(bytes32(out));
}

// slice copies len bytes from data starting at start into a new bytes array.
function slice(bytes memory data, uint256 start, uint256 len) pure returns (bytes memory out) {
  out = new bytes(len);
  for (uint256 i = 0; i < len; i++) {
    out[i] = data[start+i];
  }
}

// computeFee calls the fake exponentiation contract with the specified
// parameters to determine the correctt fee value.
function computeFee(uint256 excess) returns (uint256) {
  return callFakeExpo(1, int(excess), 17);
}

// callFakeExpo makes a raw call to the fake exponentiation contract.
function callFakeExpo(int factor, int numerator, int denominator) returns (uint256) {
  (, bytes memory data) = fakeExpo.call(bytes.concat(bytes32(uint256(factor)), bytes32(uint256(numerator)), bytes32(uint256(denominator))));
  return toFixed(data, 0, 32);
}
