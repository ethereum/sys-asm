// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

address constant registry = 0x0000000000000000000000000000000000008357;
address constant systemAddress = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
address constant user = 0x0000000000000000000000000000000000001234;

bytes32 constant K1 = bytes32(uint256(1));
bytes32 constant K2 = bytes32(uint256(2));
bytes32 constant K3 = bytes32(uint256(3));
uint256 constant I1 = 0x1501;
uint256 constant I2 = type(uint16).max;

contract VerificationKeyRegistryTest is Test {
    mapping(bytes32 => uint256) internal modelSchemaId;
    bytes32 internal modelCurrent;

    function setUp() public {
        vm.etch(registry, vm.parseBytes(vm.readFile("bytecode/verification_key_registry/main.hex")));
    }

    function schemaIdSlot(bytes32 vkHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(vkHash, uint256(1)));
    }

    function callRegistry(address from, bytes memory input, uint256 value) internal returns (bool, bytes memory) {
        vm.deal(from, value);
        vm.prank(from);
        return registry.call{value: value}(input);
    }

    function register(bytes32 vkHash, uint256 schemaId) internal returns (bool, bytes memory) {
        return callRegistry(systemAddress, abi.encodePacked(vkHash, bytes32(schemaId)), 0);
    }

    function reactivate(bytes32 vkHash) internal returns (bool, bytes memory) {
        return callRegistry(systemAddress, abi.encodePacked(vkHash), 0);
    }

    function read(bytes32 vkHash) internal returns (bool, bytes memory) {
        return callRegistry(user, abi.encodePacked(vkHash), 0);
    }

    function assertModelState() internal view {
        assertEq(vm.load(registry, bytes32(uint256(0))), modelCurrent);
        for (uint256 i = 0; i <= 4; i++) {
            bytes32 vkHash = bytes32(i);
            assertEq(vm.load(registry, schemaIdSlot(vkHash)), bytes32(modelSchemaId[vkHash]));
        }
    }

    function testConstructor() public {
        bytes memory initcode = vm.parseBytes(vm.readFile("bytecode/verification_key_registry/ctor.hex"));
        bytes memory runtime = vm.parseBytes(vm.readFile("bytecode/verification_key_registry/main.hex"));

        address deployed;
        assembly {
            deployed := create(0, add(initcode, 32), mload(initcode))
        }

        assertNotEq(deployed, address(0));
        assertEq(deployed.code, runtime);
        assertEq(runtime.length, 165);
        assertEq(initcode.length, 174);
        assertEq(keccak256(runtime), 0xd702a59db49dba5092f4e7963a25c5d89d7e64887302b536eb5041ffbe06d046);
        assertEq(keccak256(initcode), 0xc7d1f655c1f07874a5bd026ba46c017e4304e4bd78809f3cfe5e96c765076606);
        assertEq(deployed.code.length, 165);
        assertEq(deployed.balance, 0);
        assertEq(deployed.codehash, keccak256(runtime));
        assertEq(vm.load(deployed, bytes32(uint256(0))), bytes32(0));
    }

    function testRegisterAndReadCurrentOrExplicitVkHash() public {
        (bool ok, bytes memory output) = read(bytes32(0));
        assertFalse(ok);
        assertEq(output, hex"");

        (ok, output) = register(K1, I1);
        assertTrue(ok);
        assertEq(output, hex"");

        assertEq(vm.load(registry, bytes32(uint256(0))), K1);
        assertEq(vm.load(registry, schemaIdSlot(K1)), bytes32(I1));

        (ok, output) = read(bytes32(0));
        assertTrue(ok);
        assertEq(output, abi.encodePacked(K1, bytes32(I1)));

        (ok, output) = read(K1);
        assertTrue(ok);
        assertEq(output, abi.encodePacked(K1, bytes32(I1)));

        (ok, output) = read(K2);
        assertFalse(ok);
        assertEq(output, hex"");
    }

    function testRegistrationBoundsAndUniqueness() public {
        (bool ok,) = register(bytes32(0), I1);
        assertFalse(ok);

        (ok,) = register(K1, 0);
        assertFalse(ok);

        (ok,) = register(K1, I1);
        assertTrue(ok);

        (ok,) = register(K1, I2);
        assertFalse(ok);
        assertEq(vm.load(registry, schemaIdSlot(K1)), bytes32(I1));

        (ok,) = register(K2, I2);
        assertTrue(ok);
        assertEq(vm.load(registry, schemaIdSlot(K2)), bytes32(I2));

        (ok,) = register(K3, uint256(type(uint16).max) + 1);
        assertFalse(ok);
        assertEq(vm.load(registry, schemaIdSlot(K3)), bytes32(0));
    }

    function testReactivateRegisteredVkHash() public {
        (bool ok,) = register(K1, I1);
        assertTrue(ok);
        (ok,) = register(K2, I2);
        assertTrue(ok);
        assertEq(vm.load(registry, bytes32(uint256(0))), K2);

        (ok,) = reactivate(K1);
        assertTrue(ok);
        assertEq(vm.load(registry, bytes32(uint256(0))), K1);
        assertEq(vm.load(registry, schemaIdSlot(K1)), bytes32(I1));
        assertEq(vm.load(registry, schemaIdSlot(K2)), bytes32(I2));

        (ok,) = reactivate(bytes32(0));
        assertFalse(ok);
        (ok,) = reactivate(K3);
        assertFalse(ok);
        assertEq(vm.load(registry, bytes32(uint256(0))), K1);
    }

    function testRejectsInvalidCalldataLengths() public {
        uint256[6] memory invalidReadLengths = [uint256(0), 1, 31, 33, 63, 64];
        for (uint256 i = 0; i < invalidReadLengths.length; i++) {
            (bool ok, bytes memory output) = callRegistry(user, new bytes(invalidReadLengths[i]), 0);
            assertFalse(ok);
            assertEq(output, hex"");
        }

        uint256[6] memory invalidUpdateLengths = [uint256(0), 1, 31, 33, 63, 65];
        for (uint256 i = 0; i < invalidUpdateLengths.length; i++) {
            (bool ok, bytes memory output) = callRegistry(systemAddress, new bytes(invalidUpdateLengths[i]), 0);
            assertFalse(ok);
            assertEq(output, hex"");
        }
    }

    function testRejectsNonzeroValue() public {
        (bool ok, bytes memory output) = callRegistry(user, abi.encodePacked(K1), 1);
        assertFalse(ok);
        assertEq(output, hex"");

        (ok, output) = callRegistry(systemAddress, abi.encodePacked(K1, bytes32(I1)), 1);
        assertFalse(ok);
        assertEq(output, hex"");
        assertEq(registry.balance, 0);
        assertEq(vm.load(registry, bytes32(uint256(0))), bytes32(0));
    }

    function testStorageWritesAreScoped() public {
        vm.record();
        (bool ok,) = register(K1, I1);
        assertTrue(ok);
        (, bytes32[] memory writes) = vm.accesses(registry);
        assertEq(writes.length, 2);
        assertEq(writes[0], schemaIdSlot(K1));
        assertEq(writes[1], bytes32(uint256(0)));

        vm.record();
        (ok,) = reactivate(K1);
        assertTrue(ok);
        (, writes) = vm.accesses(registry);
        assertEq(writes.length, 1);
        assertEq(writes[0], bytes32(uint256(0)));

        vm.record();
        (ok,) = read(bytes32(0));
        assertTrue(ok);
        (, writes) = vm.accesses(registry);
        assertEq(writes.length, 0);

        vm.record();
        (ok,) = register(K1, I2);
        assertFalse(ok);
        (, writes) = vm.accesses(registry);
        assertEq(writes.length, 0);
    }

    function testFuzzRegisterAndRead(bytes32 vkHash, uint16 schemaId) public {
        vm.assume(vkHash != bytes32(0));
        vm.assume(schemaId != 0);

        (bool ok,) = register(vkHash, schemaId);
        assertTrue(ok);

        bytes memory output;
        (ok, output) = read(bytes32(0));
        assertTrue(ok);
        assertEq(output, abi.encodePacked(vkHash, bytes32(uint256(schemaId))));
        assertEq(vm.load(registry, schemaIdSlot(vkHash)), bytes32(uint256(schemaId)));
    }

    function testFuzzStateMachine(bytes32 seed) public {
        for (uint256 i = 0; i < 24; i++) {
            uint256 word = uint256(keccak256(abi.encode(seed, i)));
            bytes32 vkHash = bytes32(word % 5);
            uint256 schemaIdChoice = (word >> 8) % 5;
            uint256 schemaId;
            if (schemaIdChoice == 1) {
                schemaId = 1;
            } else if (schemaIdChoice == 2) {
                schemaId = type(uint16).max;
            } else if (schemaIdChoice == 3) {
                schemaId = uint256(type(uint16).max) + 1;
            } else if (schemaIdChoice == 4) {
                schemaId = word;
            }

            uint256 action = (word >> 16) % 6;
            bool expected;
            bool ok;
            bytes memory output;

            if (action == 0) {
                expected =
                    vkHash != bytes32(0) && schemaId != 0 && schemaId <= type(uint16).max && modelSchemaId[vkHash] == 0;
                (ok, output) = register(vkHash, schemaId);
                assertEq(ok, expected);
                assertEq(output, hex"");
                if (expected) {
                    modelSchemaId[vkHash] = schemaId;
                    modelCurrent = vkHash;
                }
            } else if (action == 1) {
                expected = vkHash != bytes32(0) && modelSchemaId[vkHash] != 0;
                (ok, output) = reactivate(vkHash);
                assertEq(ok, expected);
                assertEq(output, hex"");
                if (expected) {
                    modelCurrent = vkHash;
                }
            } else if (action == 2) {
                bytes32 selectedVkHash = vkHash == bytes32(0) ? modelCurrent : vkHash;
                expected = selectedVkHash != bytes32(0) && modelSchemaId[selectedVkHash] != 0;
                (ok, output) = read(vkHash);
                assertEq(ok, expected);
                bytes memory expectedOutput;
                if (expected) {
                    expectedOutput = abi.encodePacked(selectedVkHash, bytes32(modelSchemaId[selectedVkHash]));
                }
                assertEq(output, expectedOutput);
            } else if (action == 3) {
                expected = modelCurrent != bytes32(0);
                (ok, output) = read(bytes32(0));
                assertEq(ok, expected);
                bytes memory expectedOutput;
                if (expected) {
                    expectedOutput = abi.encodePacked(modelCurrent, bytes32(modelSchemaId[modelCurrent]));
                }
                assertEq(output, expectedOutput);
            } else if (action == 4) {
                address from = ((word >> 24) & 1) == 0 ? user : systemAddress;
                uint256 invalidLength = ((word >> 25) & 1) == 0 ? 31 : 33;
                (ok, output) = callRegistry(from, new bytes(invalidLength), 0);
                assertFalse(ok);
                assertEq(output, hex"");
            } else {
                address from = ((word >> 24) & 1) == 0 ? user : systemAddress;
                bytes memory input =
                    from == systemAddress ? abi.encodePacked(vkHash, bytes32(schemaId)) : abi.encodePacked(vkHash);
                (ok, output) = callRegistry(from, input, 1);
                assertFalse(ok);
                assertEq(output, hex"");
                assertEq(registry.balance, 0);
            }

            assertModelState();
        }
    }
}
