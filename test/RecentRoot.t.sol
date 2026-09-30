// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

address constant addr = 0x0000000000000000000000000000000000008272;

contract RecentRootTest is Test {
    uint256 constant RING = 8192;

    address unit;
    address shim;

    address source = address(0x01);
    bytes32 salt = bytes32(0);
    bytes32 sourceId = 0xb9382d35273c75a50631a3e84d3c75ec9266e2b18c35a627e16cdbf26a18ca85;
    bytes32 refStorageKey = 0x5f027aa1cbe2df279bf6518edd4b44ea5409fd800189ec35224e10ab05e574c3;
    bytes32 refEntryHash = 0x0a0d1254c851be5a133b4c9a9e300f5602fc0f43dbe65aa6a66930d4ca0a51b8;

    function setUp() public {
        vm.etch(addr, vm.parseBytes(vm.readFile("bytecode/recent_root/main.hex")));
        unit = addr;
        shim = address(uint160(uint256(keccak256("recent-root-number-shim"))));
        vm.etch(shim, vm.parseBytes(vm.readFile("test/recent_root_shim.hex")));
    }

    function write(uint256 slot, bytes32 root) internal {
        vm.roll(slot);
        vm.prank(source);
        (bool ok,) = shim.call(abi.encodePacked(salt, root));
        assertTrue(ok);
    }

    function tuple(uint64 slot, bytes32 root) internal view returns (bytes memory) {
        return abi.encodePacked(sourceId, slot, root);
    }

    function validate(uint256 current, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.roll(current);
        (ok, ret) = shim.staticcall(data);
    }

    function testRejectsNonzeroValue() public {
        vm.deal(address(this), 1 ether);
        (bool ret,) = unit.call{value: 1}(abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2))));
        assertFalse(ret);
        (ret,) = unit.call{value: 1}(tuple(1, bytes32(uint256(2))));
        assertFalse(ret);
    }

    function testRejectsBadCalldataSize() public {
        uint256[8] memory sizes = [uint256(0), 1, 63, 65, 71, 73, 145, 17 * 72];
        for (uint256 i = 0; i < sizes.length; i++) {
            (bool ret,) = unit.call(new bytes(sizes[i]));
            assertFalse(ret);
        }
    }

    function testWriteMatchesReferenceVector() public {
        write(1, bytes32(uint256(2)));
        assertEq(vm.load(shim, refStorageKey), refEntryHash);
        assertEq(vm.load(shim, keccak256("some-unrelated-slot")), bytes32(0));
    }

    function testWriteFailsInStaticContext() public {
        vm.roll(1);
        vm.prank(source);
        (bool ok,) = shim.staticcall(abi.encodePacked(salt, bytes32(uint256(2))));
        assertFalse(ok);
        assertEq(vm.load(shim, refStorageKey), bytes32(0));
    }

    function testValidationMatchesReferenceVector() public {
        write(1, bytes32(uint256(2)));
        bytes memory data =
            hex"b9382d35273c75a50631a3e84d3c75ec9266e2b18c35a627e16cdbf26a18ca8500000000000000010000000000000000000000000000000000000000000000000000000000000002";
        assertEq(data, tuple(1, bytes32(uint256(2))));
        (bool ok, bytes memory ret) = validate(2, data);
        assertTrue(ok);
        assertEq(ret.length, 0);
    }

    function testValidationChangesNoState() public {
        write(1, bytes32(uint256(2)));
        vm.roll(2);
        vm.record();
        (bool ok,) = shim.call(tuple(1, bytes32(uint256(2))));
        assertTrue(ok);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(shim);
        assertEq(writes.length, 0);
        assertEq(reads.length, 1);
        assertEq(reads[0], refStorageKey);
    }

    function testValidationRejectsWrongRoot() public {
        write(1, bytes32(uint256(2)));
        (bool ok,) = validate(2, tuple(1, bytes32(uint256(3))));
        assertFalse(ok);
    }

    function testValidationRejectsUnwrittenEntry() public {
        (bool ok,) = validate(2, tuple(1, bytes32(0)));
        assertFalse(ok);
    }

    function testValidationRejectsCurrentAndFutureSlot() public {
        write(1, bytes32(uint256(2)));
        (bool ok,) = validate(1, tuple(1, bytes32(uint256(2))));
        assertFalse(ok);
        (ok,) = validate(0, tuple(1, bytes32(uint256(2))));
        assertFalse(ok);
    }

    function testValidationWindowEdge() public {
        write(1, bytes32(uint256(2)));
        (bool ok,) = validate(1 + RING - 1, tuple(1, bytes32(uint256(2))));
        assertTrue(ok);
        (ok,) = validate(1 + RING, tuple(1, bytes32(uint256(2))));
        assertFalse(ok);
    }

    function testRingOverwriteInvalidatesOlderEntry() public {
        write(1, bytes32(uint256(2)));
        write(1 + RING, bytes32(uint256(5)));
        (bool ok,) = validate(2 + RING, tuple(uint64(1 + RING), bytes32(uint256(5))));
        assertTrue(ok);
        (ok,) = validate(RING, tuple(1, bytes32(uint256(2))));
        assertFalse(ok);
    }

    function testValidationLastWriteInSlotWins() public {
        write(1, bytes32(uint256(2)));
        write(1, bytes32(uint256(7)));
        (bool ok,) = validate(2, tuple(1, bytes32(uint256(2))));
        assertFalse(ok);
        (ok,) = validate(2, tuple(1, bytes32(uint256(7))));
        assertTrue(ok);
    }

    function testValidationChecksEveryTuple() public {
        write(1, bytes32(uint256(2)));
        write(3, bytes32(uint256(4)));
        (bool ok,) = validate(4, bytes.concat(tuple(1, bytes32(uint256(2))), tuple(3, bytes32(uint256(4)))));
        assertTrue(ok);
        (ok,) = validate(4, bytes.concat(tuple(1, bytes32(uint256(2))), tuple(3, bytes32(uint256(9)))));
        assertFalse(ok);
        (ok,) = validate(4, bytes.concat(tuple(1, bytes32(uint256(9))), tuple(3, bytes32(uint256(4)))));
        assertFalse(ok);
    }

    function testValidationAcceptsSixteenDuplicatesAndRejectsSeventeen() public {
        write(1, bytes32(uint256(2)));
        bytes memory one = tuple(1, bytes32(uint256(2)));
        bytes memory data;
        for (uint256 i = 0; i < 16; i++) {
            data = bytes.concat(data, one);
        }
        (bool ok,) = validate(2, data);
        assertTrue(ok);
        (ok,) = validate(2, bytes.concat(data, one));
        assertFalse(ok);
    }
}
