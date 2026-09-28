// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

address constant addr = 0x0000000000000000000000000000000000008141;

contract FramesExpiryTest is Test {
    function setUp() public {
        vm.etch(addr, vm.parseBytes(vm.readFile("bytecode/frames_expiry/main.hex")));
        vm.warp(1_700_000_000);
    }

    // verify calls the contract with an 8-byte big-endian expiry.
    function verify(uint64 expiry) internal returns (bool) {
        (bool ret, bytes memory data) = addr.call(abi.encodePacked(expiry));
        assertEq(data, hex"", "unexpected return data");
        return ret;
    }

    // testDeadline checks the timestamp boundary: expiry >= timestamp passes,
    // expiry < timestamp reverts.
    function testDeadline() public {
        uint64 ts = uint64(block.timestamp);
        assertTrue(verify(ts), "expiry == timestamp should pass");
        assertTrue(verify(ts + 1), "future expiry should pass");
        assertTrue(verify(type(uint64).max), "max expiry should pass");
        assertFalse(verify(ts - 1), "past expiry should revert");
        assertFalse(verify(0), "zero expiry should revert");
    }

    // testBadCalldataSize checks inputs that aren't exactly 8 bytes revert,
    // even when their leading bytes encode a valid future expiry.
    function testBadCalldataSize() public {
        bytes memory future = abi.encodePacked(type(uint64).max);
        bytes[5] memory inputs = [
            bytes(hex""),
            slice(future, 7),
            bytes.concat(future, hex"00"),
            bytes.concat(bytes32(type(uint256).max)),
            bytes.concat(hex"deadbeef", future)
        ];
        for (uint256 i = 0; i < inputs.length; i++) {
            (bool ret, bytes memory data) = addr.call(inputs[i]);
            assertFalse(ret);
            assertEq(data, hex"");
        }
    }

    // testDeploy checks the constructor installs the runtime code.
    function testDeploy() public {
        bytes memory initcode = vm.parseBytes(vm.readFile("bytecode/frames_expiry/ctor.hex"));
        address deployed;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        assertEq(deployed.code, addr.code);
    }

    function slice(bytes memory data, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[i];
        }
    }
}
