// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Contract.sol";

address constant addr = 0x000000000000000000000000000000000000aaaa;
address constant sysaddr = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
uint256 constant buflen = 8191;
bytes32 constant hash    = hex"88e96d4537bea4d9c05d12549907b32561d3bf31f45aae734cdc119f13406cb6";

function lastBlockNumber() view returns (bytes32) {
  return bytes32(uint256(block.number)-1);
}

function hash_idx() view returns (bytes32) {
  return bytes32(uint256(lastBlockNumber()) % buflen);
}

contract ContractTest is Test {
    function setUp() public {
        vm.etch(addr, vm.parseBytes(vm.readFile("bytecode/execution_hash/main.hex")));
    }

    // testRead verifies the contract returns the expected execution hash.
    function testExecRead() public {
        // Store hash at expected indexes.
        vm.store(addr, hash_idx(), hash);

        // Read hash associated with current timestamp.
        (bool ret, bytes memory data) = addr.call(bytes.concat(lastBlockNumber()));
        assertTrue(ret);
        assertEq(data, bytes.concat(hash));
    }

    function testReadBadCalldataSize() public {
        // Store hash at expected indexes.
        vm.store(addr, hash_idx(), hash);

        // Call with 0 byte arguement.
        (bool ret, bytes memory data) = addr.call(hex"");
        assertFalse(ret);
        assertEq(data, hex"");

        // Call with 31 byte arguement.
        (ret, data) = addr.call(hex"00000000000000000000000000000000000000000000000000000000001337");
        assertFalse(ret);
        assertEq(data, hex"");

        // Call with 33 byte arguement.
        (ret, data) = addr.call(hex"000000000000000000000000000000000000000000000000000000000000001337");
        assertFalse(ret);
        assertEq(data, hex"");
    }

    function testReadBadBlockNumbers() public {
        // Set reasonable block number.
        vm.roll(21053500);
        uint256 number = block.number-1;

        // Store hash at expected indexes.
        vm.store(addr, hash_idx(), hash);

        // Request current block.
        (bool ret, bytes memory data) = addr.call(bytes.concat(bytes32(block.number)));
        assertFalse(ret);
        assertEq(data, hex"");

        // Wrap around buflen once forward.
        (ret, data) = addr.call(bytes.concat(bytes32(number+buflen)));
        assertFalse(ret);
        assertEq(data, hex"");

        // Wrap around buflen once backward.
        (ret, data) = addr.call(bytes.concat(bytes32(number-buflen)));
        assertFalse(ret);
        assertEq(data, hex"");

        // Block number zero should fail.
        (ret, data) = addr.call(bytes.concat(bytes32(0)));
        assertFalse(ret);
        assertEq(data, hex"");
    }

    // testUpdate verifies the set functionality of the contract.
    function testUpdate() public {
        // Simulate pre-block call to set hash.
        vm.prank(sysaddr);
        (bool ret, bytes memory data) = addr.call(bytes.concat(hash));
        assertTrue(ret);
        assertEq(data, hex"");

        // Verify hash.
        bytes32 got = vm.load(addr, hash_idx());
        assertEq(got, hash);
    }

    // testRingBuffers verifies the integrity of the ring buffer is maintained
    // as the write indexes loop back to the start and begin overwriting
    // values.
    function testRingBuffers() public {
        // Set reasonable block number.
        vm.roll(21053500);

        for (uint256 i = 0; i < 10000; i += 1) {
            bytes32 pbbr = bytes32(i*1337);

            // Simulate pre-block call to set hash.
            vm.prank(sysaddr);
            (bool ret, bytes memory data) = addr.call(bytes.concat(pbbr));
            assertTrue(ret);
            assertEq(data, hex"");

            // Call contract as normal account to get exeuction hash associated
            // with current timestamp.
            (ret, data) = addr.call(bytes.concat(lastBlockNumber()));
            assertTrue(ret);
            assertEq(data, bytes.concat(pbbr));

            // Skip forward 1 block.
            vm.roll(block.number+1);
        }
    }


    // testHistoricalReads verifies that it is possible to read all previously
    // saved values in the beacon hash contract.
    function testHistoricalReads() public {
        uint256 start = 1;
        vm.roll(start);

        // Saturate storage with fake hashs.
        for (uint256 i = 0; i < buflen; i += 1) {
            bytes32 pbbr = bytes32(i*1337);
            vm.prank(sysaddr);
            (bool ret, bytes memory data) = addr.call(bytes.concat(pbbr));
            assertTrue(ret);
            assertEq(data, hex"");
            if (i+1 < buflen) {
              // Only bump block number if not last iteration.
              vm.roll(block.number+1);
            }
        }

        // Begin reading before start block, since roots are written for
        // previous.
        uint256 base = start-1;

        // Attempt to read all values in same block context.
        for (uint256 i = 0; i < buflen; i += 1) {
            bytes32 num = bytes32(uint256(base+i));
            (bool ret, bytes memory got) = addr.call(bytes.concat(num));
            assertTrue(ret);
            assertEq(got, bytes.concat(bytes32(i*1337)));
        }
    }
}
