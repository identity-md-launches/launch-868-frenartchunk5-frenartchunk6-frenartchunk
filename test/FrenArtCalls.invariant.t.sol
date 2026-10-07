// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrenArtChunk5, FrenArtChunk6, FrenArtChunk7} from "src/FrenArtChunks.sol";
import {FrenRenderer} from "src/FrenRenderer.sol";

/// @dev The chunks have STOP-only execution: arbitrary calldata cannot change art or execute a withdrawal.
///      They can receive ETH despite their nonpayable constructors. Track those unsolicited transfers;
///      this is not a deposit/withdrawal protocol and there are no depositor claims to model.
contract FrenArtCallHandler is Test {
    address[3] public chunks;
    address[3] public actors;
    uint256[3] public received;
    FrenRenderer public renderer;

    constructor(address[3] memory c, FrenRenderer r) {
        chunks = c;
        renderer = r;
        for (uint256 i; i < 3; ++i) {
            actors[i] = address(uint160(0xA1100 + i));
            vm.deal(actors[i], 100 ether);
        }
    }

    function callChunk(uint256 which, uint256 who, uint256 amount, bytes32 payload, uint256 length) public {
        which = bound(which, 0, 2);
        who = bound(who, 0, 2);
        amount = bound(amount, 0, actors[who].balance);
        length = bound(length, 0, 96);
        bytes memory data = abi.encodePacked(payload, payload, payload);
        assembly ("memory-safe") { mstore(data, length) }
        uint256 beforeBalance = actors[who].balance;
        vm.prank(actors[who]);
        (bool ok, bytes memory result) = chunks[which].call{value: amount}(data);
        assertTrue(ok, "STOP must succeed");
        assertEq(result.length, 0, "STOP returns no bytes");
        assertEq(actors[who].balance, beforeBalance - amount, "unexpected return of value");
        received[which] += amount;
    }

    function sendToRenderer(uint256 who, uint256 amount, bool withSelector) public {
        who = bound(who, 0, 2);
        // Keep the rejection path live even after a sender has transferred its entire balance to a chunk.
        // Zero-value empty calls must also revert; zero-value getter calls are exercised by the invariant.
        amount = bound(amount, 0, actors[who].balance);
        bytes memory input = withSelector && amount != 0 ? abi.encodeWithSignature("chunk7()") : bytes("");
        uint256 beforeBalance = actors[who].balance;
        vm.prank(actors[who]);
        (bool ok,) = address(renderer).call{value: amount}(input);
        assertFalse(ok, "renderer must reject ETH / empty calldata");
        assertEq(actors[who].balance, beforeBalance, "rejected transfer debited caller");
    }

    function attemptConfiguration(uint256 who, uint256 operation, address replacement) public {
        who = bound(who, 0, 2);
        operation = bound(operation, 0, 3);
        bytes4[4] memory selectors = [
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("initialize(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("setChunk7(address)"))
        ];
        vm.prank(actors[who]);
        (bool ok,) = address(renderer).call(abi.encodeWithSelector(selectors[operation], replacement));
        assertFalse(ok, "renderer has no configuration or owner");
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract FrenArtCallsInvariantTest is Test {
    address[3] chunks;
    bytes32[3] hashes;
    FrenRenderer renderer;
    bytes32 rendererHash;
    FrenArtCallHandler handler;

    function setUp() public {
        chunks[0] = address(new FrenArtChunk5());
        chunks[1] = address(new FrenArtChunk6());
        chunks[2] = address(new FrenArtChunk7());
        renderer = new FrenRenderer(
            0xa92dAcfF6d6fcC218ADe20eD24857376BD8eBE81,
            0x9666A481e20F1dB59EEbD6c43D11Ae3505468c92,
            0x71BdEB749b3ee428730eBB3E9b34B03A99D82356,
            0x0C344484D960B8474a1EdcB5A5128e8D9C9F6B4d,
            chunks[0],
            chunks[1],
            chunks[2]
        );
        handler = new FrenArtCallHandler(chunks, renderer);
        for (uint256 i; i < 3; ++i) {
            hashes[i] = chunks[i].codehash;
            handler.callChunk(i, i, 1, bytes32(0), 0); // every sequence begins with funded chunks
        }
        rendererHash = address(renderer).codehash;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.callChunk.selector;
        selectors[1] = handler.sendToRenderer.selector;
        selectors[2] = handler.attemptConfiguration.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_TransfersAreConservedAndArtCannotChange() public view {
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            assertEq(chunks[i].balance, handler.received(i), "unaccounted value movement");
            assertEq(chunks[i].codehash, hashes[i], "art changed after a call");
            total += chunks[i].balance + handler.actors(i).balance;
        }
        assertEq(total, 300 ether, "value must stay with senders or chunks");
        assertEq(address(renderer).balance, 0, "renderer accepted value");
        assertEq(address(renderer).codehash, rendererHash);
        assertEq(renderer.chunk1(), 0xa92dAcfF6d6fcC218ADe20eD24857376BD8eBE81);
        assertEq(renderer.chunk2(), 0x9666A481e20F1dB59EEbD6c43D11Ae3505468c92);
        assertEq(renderer.chunk3(), 0x71BdEB749b3ee428730eBB3E9b34B03A99D82356);
        assertEq(renderer.chunk4(), 0x0C344484D960B8474a1EdcB5A5128e8D9C9F6B4d);
        assertEq(renderer.chunk5(), chunks[0]);
        assertEq(renderer.chunk6(), chunks[1]);
        assertEq(renderer.chunk7(), chunks[2]);
    }

    function test_ZeroOneWeiAndFullBalanceCalls() public {
        for (uint256 i; i < 3; ++i) {
            handler.callChunk(i, i, 0, bytes32(0), 0);
            handler.callChunk(i, i, 1, bytes32(type(uint256).max), 96);
            handler.sendToRenderer(i, 1, false);
            handler.sendToRenderer(i, 1, true);
            handler.callChunk(i, i, handler.actors(i).balance, keccak256("withdraw()"), 4);
            handler.callChunk(i, i, 0, keccak256("destroy()"), 4);
        }
        invariant_TransfersAreConservedAndArtCannotChange();
    }

    function test_LaunchConstructorsRejectValue() public {
        bytes[] memory codes = new bytes[](4);
        codes[0] = type(FrenArtChunk5).creationCode;
        codes[1] = type(FrenArtChunk6).creationCode;
        codes[2] = type(FrenArtChunk7).creationCode;
        codes[3] = abi.encodePacked(
            type(FrenRenderer).creationCode,
            abi.encode(
                renderer.chunk1(),
                renderer.chunk2(),
                renderer.chunk3(),
                renderer.chunk4(),
                chunks[0],
                chunks[1],
                chunks[2]
            )
        );
        vm.deal(address(this), 1);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            address deployed;
            assembly ("memory-safe") { deployed := create(1, add(code, 32), mload(code)) }
            assertEq(deployed, address(0), "nonpayable constructor accepted value");
            assertEq(address(this).balance, 1, "failed deployment retained ETH");
        }
    }
}
