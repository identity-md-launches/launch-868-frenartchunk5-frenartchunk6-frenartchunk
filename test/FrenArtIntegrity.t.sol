// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrenRenderer} from "src/FrenRenderer.sol";
import {FrenArtIndex} from "src/FrenArtIndex.sol";
import {ImdStyleArtLaunches} from "./FrenRenderer.t.sol";

/// @dev Exposes only the real reader, so every entry can be checked against the independent binary fixtures.
///      Tests restrict i to the 69 layers and palette; arbitrary internal indices are not a public API.
contract FrenEntryProbe is FrenRenderer {
    constructor(address[7] memory c) FrenRenderer(c[0], c[1], c[2], c[3], c[4], c[5], c[6]) {}

    function entry(uint256 i) external view returns (bytes memory) {
        return _entry(i);
    }
}

contract FrenArtIntegrityTest is Test {
    string constant ART = "script/art/data/";
    address[7] chunks;
    FrenRenderer renderer;
    FrenEntryProbe reader;

    function setUp() public {
        ImdStyleArtLaunches factory = new ImdStyleArtLaunches();
        (chunks[0], chunks[1]) = factory.launch1();
        (chunks[2], chunks[3]) = factory.launch2();
        address r;
        (chunks[4], chunks[5], chunks[6], r) = factory.launch3(chunks[0], chunks[1], chunks[2], chunks[3]);
        renderer = FrenRenderer(r);
        reader = new FrenEntryProbe(chunks);
    }

    function test_EveryEntryMatchesOriginalBinary() public view {
        string memory manifest = vm.readFile(string.concat(ART, "manifest.json"));
        string[] memory names = vm.parseJsonStringArray(manifest, ".layers");
        assertEq(names.length, 69);
        for (uint256 i; i < names.length; ++i) {
            assertEq(reader.entry(i), vm.readFileBinary(string.concat(ART, "layers/", names[i], ".bin")), names[i]);
        }
        // The palette starts at an unaligned framed offset and ends in chunk 7's partially filled last frame.
        assertEq(reader.entry(69), vm.readFileBinary(string.concat(ART, "palette.bin")), "palette");
        assertEq(FrenArtIndex.TABLES, vm.readFileBinary(string.concat(ART, "tables.bin")));
        assertEq(FrenArtIndex.FACE_TABLE, vm.readFileBinary(string.concat(ART, "facetable.bin")));
        assertEq(renderer.shadow(), vm.parseJsonUint(manifest, ".shadow"));
        assertEq(renderer.faceLayers(), 39);
    }

    function test_LaunchThreeRuntimeBytesAndFraming() public view {
        // Build expectations from the original art files, independently of the generated index/reader.
        assertEq(chunks[4].code, bytes.concat(hex"00", _background(2), _background(3), _background(4)));
        assertEq(chunks[5].code, bytes.concat(hex"00", _background(5), _background(6), _background(7)));
        bytes memory payload =
            bytes.concat(_background(8), _background(9), vm.readFileBinary(string.concat(ART, "palette.bin")));
        bytes memory code = chunks[6].code;
        assertEq(code.length, 8944);
        assertEq(code[0], bytes1(0));
        uint256 cursor = 1;
        for (uint256 i; i < payload.length; i += 32) {
            assertEq(code[cursor++], bytes1(0x7f), "PUSH32 frame");
            for (uint256 j; j < 32; ++j) {
                assertEq(code[cursor++], i + j < payload.length ? payload[i + j] : bytes1(0), "data/padding");
            }
        }
        assertEq(cursor, code.length, "no trailing runtime");
    }

    function test_EveryChunkRejectsMissingTruncatedExtendedOrSubstitutedCode() public {
        for (uint256 c; c < 7; ++c) {
            bytes memory original = chunks[c].code;
            // A successful read precedes each change: authentication must not be cached by the constructor/read.
            assertGt(reader.entry(_firstEntry(c)).length, 0);
            vm.etch(chunks[c], hex"");
            _assertBadChunk(c);
            vm.etch(chunks[c], hex"00");
            _assertBadChunk(c);
            vm.etch(chunks[c], chunks[(c + 1) % 7].code);
            _assertBadChunk(c);
            vm.etch(chunks[c], bytes.concat(original, hex"00"));
            _assertBadChunk(c);
            bytes memory shortened = new bytes(original.length - 1);
            for (uint256 i; i < shortened.length; ++i) {
                shortened[i] = original[i];
            }
            vm.etch(chunks[c], shortened);
            _assertBadChunk(c);
            vm.etch(chunks[c], original);
            assertGt(reader.entry(_firstEntry(c)).length, 0, "restored art");
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_AnyChangedByteInvalidatesTheWholeChunk(uint256 c, uint256 offset, uint8 xorMask) public {
        c = bound(c, 0, 6);
        bytes memory code = chunks[c].code;
        offset = bound(offset, 0, code.length - 1);
        xorMask = uint8(bound(xorMask, 1, 255));
        bytes memory beforeRead = reader.entry(_firstEntry(c));
        code[offset] ^= bytes1(xorMask);
        vm.etch(chunks[c], code);
        _assertBadChunk(c);
        code[offset] ^= bytes1(xorMask);
        vm.etch(chunks[c], code);
        assertEq(reader.entry(_firstEntry(c)), beforeRead);
    }

    function test_StopFrameMarkersAndUnusedPaddingAreAuthenticated() public {
        for (uint256 c; c < 7; ++c) {
            bytes memory code = chunks[c].code;
            uint256[3] memory offsets = [uint256(0), 1, code.length - 1];
            for (uint256 j; j < offsets.length; ++j) {
                code[offsets[j]] ^= bytes1(0x01);
                vm.etch(chunks[c], code);
                _assertBadChunk(c);
                code[offsets[j]] ^= bytes1(0x01);
            }
            vm.etch(chunks[c], code);
        }
    }

    function test_PaletteIsCheckedEvenWhenCanvasDoesNotUseChunkSeven() public {
        bytes memory canvas = renderer.canvas(0, 0); // background 0, face 0 and coat 0 are elsewhere
        bytes memory code = chunks[6].code;
        code[code.length - 1] ^= bytes1(0x01); // unused padding still changes the authenticated code hash
        vm.etch(chunks[6], code);
        assertEq(renderer.canvas(0, 0), canvas);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        renderer.bmp(0, 0);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        renderer.tokenURI(1, 0, 0);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        renderer.pendingURI(1);
    }

    function test_AllZeroAddressesDeployButArtReadsFail() public {
        FrenRenderer empty =
            new FrenRenderer(address(0), address(0), address(0), address(0), address(0), address(0), address(0));
        assertEq(empty.chunk1(), address(0));
        assertEq(empty.chunk7(), address(0));
        assertEq(empty.attributes(0), renderer.attributes(0)); // pure metadata needs no chunk
        vm.expectRevert(FrenRenderer.BadArt.selector);
        empty.canvas(0, 0);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        empty.bmp(0, 0);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        empty.tokenURI(1, 0, 0);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        empty.unrevealed(1);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        empty.pendingURI(1);
    }

    function _assertBadChunk(uint256 c) internal {
        uint256 entry = _firstEntry(c);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        reader.entry(entry);
        // Each witness deliberately reads the selected chunk through the production public API.
        uint24[7] memory combos =
            [uint24(0), uint24(1 | 1 << 2), uint24(1 | 12 << 2), 0, uint24(2 << 15), uint24(5 << 15), uint24(8 << 15)];
        vm.expectRevert(FrenRenderer.BadArt.selector);
        renderer.canvas(combos[c], 0);
    }

    function _firstEntry(uint256 c) internal pure returns (uint256) {
        uint256[7] memory entries = [uint256(0), 14, 25, 37, 61, 64, 67];
        return entries[c];
    }

    function _background(uint256 i) internal view returns (bytes memory) {
        return vm.readFileBinary(string.concat(ART, "layers/bg", vm.toString(i), ".bin"));
    }
}
