// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Contract.sol";

address constant addr = 0x0000000000000000000000000000000000000bBB;
address constant sysaddr = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
uint256 constant buflen = 8191;
bytes32 constant root    = hex"88e96d4537bea4d9c05d12549907b32561d3bf31f45aae734cdc119f13406cb6";

function timestamp() view returns (bytes32) {
        return bytes32(uint256(block.timestamp));
}

function timestamp_idx() view returns (bytes32) {
        return bytes32(uint256(block.timestamp % buflen));
}

function root_idx() view returns (bytes32) {
        return bytes32(uint256(block.timestamp % buflen + buflen));
}

contract ContractTest is Test {
    address unit;

    // EIP-4788 deployment input without its 9-byte constructor prefix.
    // https://eips.ethereum.org/EIPS/eip-4788#deployment
    bytes constant deployedCode = hex"3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500";

    function setUp() public {
        vm.etch(addr, vm.parseBytes(vm.readFile("bytecode/beacon_root/main.hex")));
        unit = addr;
    }

    function testRuntimeBytecode() public view {
        assertEq(unit.code, deployedCode);
    }

    function testDeploymentBytecode() public view {
        bytes memory initcode = vm.parseBytes(vm.readFile("bytecode/beacon_root/ctor.hex"));
        assertEq(initcode, bytes.concat(hex"60618060095f395ff3", deployedCode));
    }

    // testRead verifies the contract returns the expected beacon root.
    function testRead() public {
        // Store timestamp and root at expected indexes.
        vm.store(unit, timestamp_idx(), timestamp());
        vm.store(unit, root_idx(), root);

        // Read root associated with current timestamp.
        (bool ret, bytes memory data) = unit.call(bytes.concat(timestamp()));
        assertTrue(ret);
        assertEq(data, bytes.concat(root));
    }

    function testReadBadCalldataSize() public {
        uint256 time = block.timestamp;

        // Store timestamp and root at expected indexes.
        vm.store(unit, timestamp_idx(), bytes32(time));
        vm.store(unit, root_idx(), root);

        // Call with 0 byte arguement.
        (bool ret, bytes memory data) = unit.call(hex"");
        assertFalse(ret);
        assertEq(data, hex"");

        // Call with 31 byte arguement.
        (ret, data) = unit.call(hex"00000000000000000000000000000000000000000000000000000000001337");
        assertFalse(ret);
        assertEq(data, hex"");

        // Call with 33 byte arguement.
        (ret, data) = unit.call(hex"000000000000000000000000000000000000000000000000000000000000001337");
        assertFalse(ret);
        assertEq(data, hex"");
    }

    function testReadWrongTimestamp() public {
        // Set reasonable timestamp.
        vm.warp(1641070800);
        uint256 time = block.timestamp;

        // Store timestamp and root at expected indexes.
        vm.store(unit, timestamp_idx(), bytes32(time));
        vm.store(unit, root_idx(), root);

        // Wrap around buflen once forward.
        (bool ret, bytes memory data) = unit.call(bytes.concat(bytes32(time+buflen)));
        assertFalse(ret);
        assertEq(data, hex"");

        // Wrap around buflen once backward.
        (ret, data) = unit.call(bytes.concat(bytes32(time-buflen)));
        assertFalse(ret);
        assertEq(data, hex"");

        // Timestamp without any associated root.
        (ret, data) = unit.call(bytes.concat(bytes32(time+1)));
        assertFalse(ret);
        assertEq(data, hex"");

        // Timestamp zero should fail.
        (ret, data) = unit.call(bytes.concat(bytes32(0)));
        assertFalse(ret);
        assertEq(data, hex"");
    }

    // testUpdate verifies the set functionality of the contract.
    function testUpdate() public {
        // Simulate pre-block call to set root.
        vm.prank(sysaddr);
        (bool ret, bytes memory data) = unit.call(bytes.concat(root));
        assertTrue(ret);
        assertEq(data, hex"");

        // Verify timestamp.
        bytes32 got = vm.load(unit, timestamp_idx());
        assertEq(got, timestamp());

        // Verify root.
        got = vm.load(unit, root_idx());
        assertEq(got, root);
    }

    // testRingBuffers verifies the integrity of the ring buffer is maintained
    // as the write indexes loop back to the start and begin overwriting
    // values.
    function testRingBuffers() public {
        for (uint256 i = 0; i < 10000; i += 1) {
            bytes32 pbbr = bytes32(i*1337);

            // Simulate pre-block call to set root.
            vm.prank(sysaddr);
            (bool ret, bytes memory data) = unit.call(bytes.concat(pbbr));
            assertTrue(ret);
            assertEq(data, hex"");

            // Call contract as normal account to get beacon root associated
            // with current timestamp.
            (ret, data) = unit.call(bytes.concat(timestamp()));
            assertTrue(ret);
            assertEq(data, bytes.concat(pbbr));

            // Skip forward 12 seconds.
            skip(12);
        }
    }


    // testHistoricalReads verifies that it is possible to read all previously
    // saved values in the beacon root contract.
    function testHistoricalReads() public {
        uint256 start = block.timestamp;

        // Saturate storage with fake roots.
        for (uint256 i = 0; i < buflen; i += 1) {
            bytes32 pbbr = bytes32(i*1337);
            vm.prank(sysaddr);
            (bool ret, bytes memory data) = unit.call(bytes.concat(pbbr));
            assertTrue(ret);
            assertEq(data, hex"");
            skip(12);
        }

        // Attempt to read all values in same block context.
        for (uint256 i = 0; i < buflen; i += 1) {
            bytes32 time = bytes32(uint256(start+i*12));
            (bool ret, bytes memory got) = unit.call(bytes.concat(time));
            assertTrue(ret);
            assertEq(got, bytes.concat(bytes32(i*1337)));
        }
    }
}
