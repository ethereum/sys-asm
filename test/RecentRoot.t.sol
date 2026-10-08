// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

contract RecentRootTest is Test {
    uint64 constant RING = 8192;

    address constant unit = 0x8272D9679689Ea2f307140CdF9002D27dC00Ffff;

    address source = address(0x01);
    bytes32 salt = bytes32(0);
    bytes32 sourceId = 0xb9382d35273c75a50631a3e84d3c75ec9266e2b18c35a627e16cdbf26a18ca85;
    bytes32 refStorageKey = 0x5f027aa1cbe2df279bf6518edd4b44ea5409fd800189ec35224e10ab05e574c3;
    bytes32 refEntryHash = 0x0a0d1254c851be5a133b4c9a9e300f5602fc0f43dbe65aa6a66930d4ca0a51b8;

    function setUp() public {
        vm.etch(unit, vm.parseBytes(vm.readFile("bytecode/recent_root/main.hex")));
    }

    function write(uint64 slot, bytes32 root) internal {
        vm.rollSlot(slot);
        vm.prank(source);
        (bool ok,) = unit.call(abi.encodePacked(salt, root));
        assertTrue(ok);
    }

    function tuple(uint64 slot, bytes32 root) internal view returns (bytes memory) {
        return abi.encodePacked(sourceId, slot, root);
    }

    function validate(uint64 current, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.rollSlot(current);
        (ok, ret) = unit.staticcall(data);
    }

    function prefix(bytes memory data, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[i];
        }
    }

    function testRejectsNonzeroValue() public {
        bytes32 root = bytes32(uint256(2));
        vm.deal(source, 1 ether);
        vm.rollSlot(1);
        vm.prank(source);
        (bool ok,) = unit.call{value: 1}(abi.encodePacked(salt, root));
        assertFalse(ok);
        assertEq(vm.load(unit, refStorageKey), bytes32(0));

        // The same write, and a validation of it, succeed without value.
        write(1, root);
        vm.rollSlot(2);
        vm.deal(address(this), 1 ether);
        (ok,) = unit.call{value: 1}(tuple(1, root));
        assertFalse(ok);
        (ok,) = unit.call(tuple(1, root));
        assertTrue(ok);
    }

    function testRejectsBadCalldataSize() public {
        // The root ends in zero bytes, so a tuple cut short inside its root
        // zero-pads back to a valid tuple unless the length is checked.
        bytes32 root = bytes32(bytes1(0x02));
        write(1, root);
        bytes memory one = tuple(1, root);
        bytes memory sixteen;
        for (uint256 i = 0; i < 16; i++) {
            sixteen = bytes.concat(sixteen, one);
        }
        (bool ok,) = validate(2, one);
        assertTrue(ok);
        (ok,) = validate(2, sixteen);
        assertTrue(ok);

        bytes[6] memory bad = [
            bytes(""),
            prefix(one, 41),
            prefix(one, 71),
            bytes.concat(one, hex"00"),
            bytes.concat(one, prefix(one, 71)),
            prefix(sixteen, 16 * 72 - 1)
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            (ok,) = validate(2, bad[i]);
            assertFalse(ok);
        }
    }

    function testWriteMatchesReferenceVector() public {
        write(1, bytes32(uint256(2)));
        assertEq(vm.load(unit, refStorageKey), refEntryHash);
        assertEq(vm.load(unit, keccak256("some-unrelated-slot")), bytes32(0));
    }

    function testWriteFailsInStaticContext() public {
        vm.rollSlot(1);
        vm.prank(source);
        (bool ok,) = unit.staticcall(abi.encodePacked(salt, bytes32(uint256(2))));
        assertFalse(ok);
        assertEq(vm.load(unit, refStorageKey), bytes32(0));
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
        vm.rollSlot(2);
        vm.record();
        (bool ok,) = unit.call(tuple(1, bytes32(uint256(2))));
        assertTrue(ok);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(unit);
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
        (bool ok,) = validate(2 + RING, tuple(1 + RING, bytes32(uint256(5))));
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
