// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./Test.sol";

contract FakeExpoTest is Test {
  function setUp() public {
    vm.etch(fakeExpo, vm.parseBytes(vm.readFile("bytecode/fake_expo_test/main.hex")));
  }

  // testFakeExpo calls the fake exponentiation logic with specific values.
  function testFakeExpo() public {
    assertEq(callFakeExpo(1, 100, 17), 357);
  }
}
