// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrenRenderer} from "../src/FrenRenderer.sol";
import {
    FrenArtChunk1,
    FrenArtChunk2,
    FrenArtChunk3,
    FrenArtChunk4,
    FrenArtChunk5,
    FrenArtChunk6,
    FrenArtChunk7
} from "../src/FrenArtChunks.sol";
import {FrenArtRef, FrenRendererRef} from "./ref/FrenRendererRef.sol";
import {LaunchGasFactory} from "./LaunchGasFactory.sol";

/// @dev What IMD's launch factory does with `evm_contracts`, three times: each launch's contracts in order, in one
///      transaction, constructors only. The third names the first two launches' chunks by address.
contract ImdStyleArtLaunches {
    function launch1() external returns (address c1, address c2) {
        c1 = address(new FrenArtChunk1());
        c2 = address(new FrenArtChunk2());
    }

    function launch2() external returns (address c3, address c4) {
        c3 = address(new FrenArtChunk3());
        c4 = address(new FrenArtChunk4());
    }

    function launch3(address c1, address c2, address c3, address c4)
        external
        returns (address c5, address c6, address c7, address r)
    {
        c5 = address(new FrenArtChunk5());
        c6 = address(new FrenArtChunk6());
        c7 = address(new FrenArtChunk7());
        r = address(new FrenRenderer(c1, c2, c3, c4, c5, c6, c7));
    }
}

/// @notice The chunk renderer, deployed as IMD would in three launches, draws exactly what the art kit's reference draws
///         and returns exactly the metadata of the renderer the frens launch with; it takes only this art.
contract FrenRendererTest is Test {
    string constant ART = "script/art/data/";

    FrenRenderer r;
    FrenRendererRef ref;
    address[7] chunks;

    function setUp() public {
        ImdStyleArtLaunches f = new ImdStyleArtLaunches();
        (chunks[0], chunks[1]) = f.launch1();
        (chunks[2], chunks[3]) = f.launch2();
        address rr;
        (chunks[4], chunks[5], chunks[6], rr) = f.launch3(chunks[0], chunks[1], chunks[2], chunks[3]);
        r = FrenRenderer(rr);
        ref = _reference();
    }

    /// @dev The launch renderer, its art written as the frens' deploy script writes it
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
            art.write(pal)[0],
            ptrs,
            vm.readFileBinary(string.concat(ART, "tables.bin")),
            vm.readFileBinary(string.concat(ART, "facetable.bin")),
            uint8(vm.parseJsonUint(manifest, ".shadow"))
        );
    }

    /// @dev A random combo inside the art: every trait at one of its values
    function _combo(uint256 x) internal pure returns (uint24) {
        uint256[8] memory n = [uint256(3), 13, 4, 3, 6, 3, 10, 16];
        uint256[8] memory shift = [uint256(0), 2, 6, 8, 10, 13, 15, 19];
        uint256 c;
        for (uint256 t; t < 8; ++t) {
            c |= ((uint256(keccak256(abi.encode(x, t))) % n[t]) << shift[t]);
        }
        return uint24(c);
    }

    /* ── the art ─────────────────────────────────────────────────── */

    function test_MatchesTheReference() public view {
        string memory exp = vm.readFile(string.concat(ART, "expected.json"));
        uint256 i;
        for (; vm.keyExistsJson(exp, string.concat(".[", vm.toString(i), "]")); ++i) {
            string memory k = string.concat(".[", vm.toString(i), "]");
            uint24 combo = uint24(vm.parseJsonUint(exp, string.concat(k, ".combo")));
            uint256 seed = vm.parseUint(vm.parseJsonString(exp, string.concat(k, ".seed")));
            bytes32 want = vm.parseJsonBytes32(exp, string.concat(k, ".bmpSha256"));
            assertEq(sha256(r.bmp(combo, seed)), want, "the bitmap differs from the reference");
        }
        assertGe(i, 6);
    }

    /// @dev Byte for byte the launch renderer's tokenURI and pendingURI, over random frens and every background
    function test_SameAsTheLaunchRenderer() public view {
        for (uint256 i; i < 24; ++i) {
            uint24 combo = _combo(i);
            uint256 seed = uint256(keccak256(abi.encode("seed", i)));
            assertEq(
                keccak256(bytes(r.tokenURI(i + 1, combo, seed))),
                keccak256(bytes(ref.tokenURI(i + 1, combo, seed))),
                "tokenURI"
            );
        }
        for (uint256 bg; bg < 10; ++bg) {
            uint24 combo = uint24(_combo(100 + bg) & ~uint256(15 << 15) | bg << 15);
            assertEq(keccak256(r.canvas(combo, bg)), keccak256(ref.canvas(combo, bg)), "canvas");
        }
        for (uint256 id = 1; id < 2222; id += 317) {
            assertEq(keccak256(bytes(r.pendingURI(id))), keccak256(bytes(ref.pendingURI(id))), "pendingURI");
        }
        assertEq(r.attributes(_combo(7)), ref.attributes(_combo(7)));
    }

    function test_RejectsCombosOutsideTheArt() public {
        uint24[6] memory bad =
            [uint24(3), uint24(13 << 2), uint24(3 << 8), uint24(6 << 10), uint24(3 << 13), uint24(10 << 15)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(); // Missing, or an out-of-range read of the index
            r.canvas(bad[i], 0);
        }
        r.canvas(uint24(2 | 12 << 2 | 3 << 6 | 2 << 8 | 5 << 10 | 2 << 13 | 9 << 15 | 15 << 19), 1); // every trait at its last value
    }

    function test_TokenURIIsCheapEnoughToRead() public {
        uint24 combo = uint24(1 | 3 << 2 | 1 << 6 | 2 << 8 | 2 << 10 | 5 << 15 | 13 << 19);
        uint256 g = gasleft();
        string memory uri = r.tokenURI(2222, combo, 424242);
        emit log_named_uint("tokenURI gas", g - gasleft());
        assertLt(g - gasleft(), 30_000_000);
        assertEq(bytes(uri)[0], "d");
    }

    /// @dev Explicit eth_call budgets for the audit's examples. Providers must also allow the consumer's overhead.
    function test_MetadataFitsThirtyMillionGas() public {
        bytes memory input = abi.encodeCall(FrenRenderer.tokenURI, (1, uint24(0xbd59c), 42));
        uint256 g = gasleft();
        (bool ok, bytes memory result) = address(r).staticcall{gas: 30_000_000}(input);
        emit log_named_uint("tokenURI sample gas", g - gasleft());
        assertTrue(ok, "tokenURI exceeds the sample RPC budget");
        assertEq(abi.decode(result, (string)), ref.tokenURI(1, 0xbd59c, 42));

        input = abi.encodeCall(FrenRenderer.pendingURI, (1));
        g = gasleft();
        (ok, result) = address(r).staticcall{gas: 30_000_000}(input);
        emit log_named_uint("pendingURI sample gas", g - gasleft());
        assertTrue(ok, "pendingURI exceeds the sample RPC budget");
        assertEq(abi.decode(result, (string)), ref.pendingURI(1));
    }

    /* ── the launches ────────────────────────────────────────────── */

    // Deployment gas is checked from a local Anvil receipt by script/check_launch_gas.py.
    // Forge's gasleft() deltas around CREATE omit code-deposit costs in the audited toolchain.

    /// @dev The renderer draws only these chunks, in this order: anything else and every read reverts
    function test_DrawsOnlyThisArt() public {
        FrenRenderer swapped =
            new FrenRenderer(chunks[1], chunks[0], chunks[2], chunks[3], chunks[4], chunks[5], chunks[6]);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        swapped.tokenURI(1, 0, 0);
        FrenRenderer stranger =
            new FrenRenderer(chunks[0], chunks[1], chunks[2], chunks[3], chunks[4], chunks[5], address(0xBEEF));
        vm.expectRevert(FrenRenderer.BadArt.selector);
        stranger.pendingURI(1);
        assertEq(r.chunk7(), chunks[6]);
    }

    /// @dev IMD's admission deploys launch 3 on a fresh chain, where launches 1 and 2's chunks don't exist: the
    ///      renderer must still deploy there (it reads nothing until asked to draw)
    function test_DeploysWithoutTheEarlierChunks() public {
        LaunchGasFactory factory = new LaunchGasFactory();
        bytes[] memory codes = new bytes[](4);
        codes[0] = type(FrenArtChunk5).creationCode;
        codes[1] = type(FrenArtChunk6).creationCode;
        codes[2] = type(FrenArtChunk7).creationCode;
        address c5 = _predicted(address(factory), 0, codes[0]);
        address c6 = _predicted(address(factory), 1, codes[1]);
        address c7 = _predicted(address(factory), 2, codes[2]);
        codes[3] = abi.encodePacked(
            type(FrenRenderer).creationCode,
            abi.encode(
                0xa92dAcfF6d6fcC218ADe20eD24857376BD8eBE81,
                0x9666A481e20F1dB59EEbD6c43D11Ae3505468c92,
                0x71BdEB749b3ee428730eBB3E9b34B03A99D82356,
                0x0C344484D960B8474a1EdcB5A5128e8D9C9F6B4d,
                c5,
                c6,
                c7
            )
        );
        address[] memory deployed = factory.deploy(codes);
        for (uint256 i; i < deployed.length; ++i) {
            assertEq(deployed[i], _predicted(address(factory), i, codes[i]));
            _assertAdmitted(deployed[i]);
        }
        FrenRenderer alone = FrenRenderer(deployed[3]);
        assertEq(alone.chunk1(), 0xa92dAcfF6d6fcC218ADe20eD24857376BD8eBE81);
        assertEq(alone.chunk2(), 0x9666A481e20F1dB59EEbD6c43D11Ae3505468c92);
        assertEq(alone.chunk3(), 0x71BdEB749b3ee428730eBB3E9b34B03A99D82356);
        assertEq(alone.chunk4(), 0x0C344484D960B8474a1EdcB5A5128e8D9C9F6B4d);
        assertEq(alone.chunk5(), c5);
        assertEq(alone.chunk6(), c6);
        assertEq(alone.chunk7(), c7);
        assertEq(alone.chunk1().code.length, 0);
        assertEq(alone.chunk2().code.length, 0);
        assertEq(alone.chunk3().code.length, 0);
        assertEq(alone.chunk4().code.length, 0);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        alone.tokenURI(1, 0, 0);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        alone.pendingURI(1);
    }

    function _predicted(address factory, uint256 salt, bytes memory code) internal pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, bytes32(salt), keccak256(code)))))
            );
    }

    /// @dev IMD's launch admission reads code as instructions (PUSH data skipped) and refuses CALLCODE, DELEGATECALL
    ///      and SELFDESTRUCT bytes even in code that never runs: every chunk must read clean
    function test_ChunksPassTheAdmissionScan() public view {
        for (uint256 k; k < 7; ++k) {
            _assertAdmitted(chunks[k]);
        }
    }

    function test_RendererPassesTheAdmissionScan() public view {
        _assertAdmitted(address(r));
    }

    /// @dev Identical bounds and instruction walk to the protected launch admission check.
    function _assertAdmitted(address application) internal view {
        bytes memory code = application.code;
        assertGt(code.length, 0, "missing runtime");
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }
}
