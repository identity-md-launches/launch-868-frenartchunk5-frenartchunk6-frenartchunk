// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrenRenderer} from "../src/FrenRenderer.sol";
import {FrenArtRef, FrenRendererRef} from "./ref/FrenRendererRef.sol";

/// @notice On a mainnet fork, the renderer the swarm deployed (IMD launch 3): it reads the seven swarm chunks, draws every
///         reference bitmap, and returns byte for byte the launch renderer's metadata, revealed and unrevealed.
///   RENDERER=0x… MAINNET_RPC_URL=… forge test --match-path test/OnChainRenderer.fork.t.sol
contract OnChainRendererForkTest is Test {
    string constant ART = "script/art/data/";
    address constant CHUNK1 = 0xa92dAcfF6d6fcC218ADe20eD24857376BD8eBE81; // launch 819
    address constant CHUNK2 = 0x9666A481e20F1dB59EEbD6c43D11Ae3505468c92;
    address constant CHUNK3 = 0x71BdEB749b3ee428730eBB3E9b34B03A99D82356; // launch 838
    address constant CHUNK4 = 0x0C344484D960B8474a1EdcB5A5128e8D9C9F6B4d;

    FrenRenderer r;
    FrenRendererRef ref;

    function setUp() public {
        string memory rpc_ = vm.envOr("MAINNET_RPC_URL", string(""));
        address deployed = vm.envOr("RENDERER", address(0));
        if (bytes(rpc_).length == 0 || deployed == address(0)) vm.skip(true);
        vm.createSelectFork(rpc_);
        r = FrenRenderer(deployed);
        ref = _reference();
    }

    function _reference() internal returns (FrenRendererRef) {
        FrenArtRef art = new FrenArtRef();
        string memory manifest = vm.readFile(string.concat(ART, "manifest.json"));
        string[] memory names = vm.parseJsonStringArray(manifest, ".layers");
        address[] memory ptrs = new address[](names.length);
        for (uint256 i; i < names.length; ++i) {
            bytes[] memory one = new bytes[](1);
            one[0] = vm.readFileBinary(string.concat(ART, "layers/", names[i], ".bin"));
            ptrs[i] = art.write(one)[0];
        }
        bytes[] memory pal = new bytes[](1);
        pal[0] = vm.readFileBinary(string.concat(ART, "palette.bin"));
        return new FrenRendererRef(
            art.write(pal)[0], ptrs, vm.readFileBinary(string.concat(ART, "tables.bin")),
            vm.readFileBinary(string.concat(ART, "facetable.bin")), uint8(vm.parseJsonUint(manifest, ".shadow"))
        );
    }

    function test_readsTheSwarmChunks() public view {
        assertEq(r.chunk1(), CHUNK1);
        assertEq(r.chunk2(), CHUNK2);
        assertEq(r.chunk3(), CHUNK3);
        assertEq(r.chunk4(), CHUNK4);
        assertGt(r.chunk5().code.length, 0);
        assertGt(r.chunk6().code.length, 0);
        assertGt(r.chunk7().code.length, 0);
    }

    function test_drawsTheReference() public view {
        string memory exp = vm.readFile(string.concat(ART, "expected.json"));
        uint256 i;
        for (; vm.keyExistsJson(exp, string.concat(".[", vm.toString(i), "]")); ++i) {
            string memory k = string.concat(".[", vm.toString(i), "]");
            uint24 combo = uint24(vm.parseJsonUint(exp, string.concat(k, ".combo")));
            uint256 seed = vm.parseUint(vm.parseJsonString(exp, string.concat(k, ".seed")));
            assertEq(sha256(r.bmp(combo, seed)), vm.parseJsonBytes32(exp, string.concat(k, ".bmpSha256")), "bitmap");
        }
        assertGe(i, 6);
    }

    function test_sameMetadataAsTheLaunchRenderer() public view {
        uint24[4] memory combos = [uint24(0xbd59c), uint24(0x7a8a30), uint24(0x80171), uint24(0x3c9002)];
        for (uint256 i; i < combos.length; ++i) {
            assertEq(keccak256(bytes(r.tokenURI(i + 1, combos[i], i * 7919))), keccak256(bytes(ref.tokenURI(i + 1, combos[i], i * 7919))), "tokenURI");
        }
        for (uint256 id = 1; id < 2222; id += 555) {
            assertEq(keccak256(bytes(r.pendingURI(id))), keccak256(bytes(ref.pendingURI(id))), "pendingURI");
        }
    }
}
