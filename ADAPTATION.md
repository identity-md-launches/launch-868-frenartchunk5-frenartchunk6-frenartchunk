# Launch 3 adaptation

This is a contracts-only launch of the existing art. All four application constructors already meet the factory's
requirements: nonpayable, static arguments, fully configured at construction, no owner or initialization calls.
No application behavior needed changing. `src/FrenArtChunks.sol`, `src/FrenArtIndex.sol`, the art data, configuration
and dependencies are unchanged. No token or launch manifest was added.

Deployment order and arguments remain:

1. `FrenArtChunk5` (`src/FrenArtChunks.sol`): no arguments.
2. `FrenArtChunk6` (`src/FrenArtChunks.sol`): no arguments.
3. `FrenArtChunk7` (`src/FrenArtChunks.sol`): no arguments.
4. `FrenRenderer` (`src/FrenRenderer.sol`), seven addresses in this order:
   `0xa92dAcfF6d6fcC218ADe20eD24857376BD8eBE81`,
   `0x9666A481e20F1dB59EEbD6c43D11Ae3505468c92`,
   `0x71BdEB749b3ee428730eBB3E9b34B03A99D82356`,
   `0x0C344484D960B8474a1EdcB5A5128e8D9C9F6B4d`,
   `$contract:FrenArtChunk5`, `$contract:FrenArtChunk6`, `$contract:FrenArtChunk7`.

## Changes and audit disposition

Finding IDs below use their unique first eight hexadecimal characters from the supplied audit.

| Finding | Reproduction and disposition | Changes and verification |
|---|---|---|
| `14c1b56e`: understated deployment gas | Reproduced on Foundry 1.8.5 / solc 0.8.26. The old test logged 1,000,622 / 957,524 / 1,310,335 gas. A scratch external creation of chunk 5 reported 24,616 gas versus 3,880,600 for code deposit alone; `lastCallGas` also omitted it. Ethereum receipts for #819 and #838 report 11,290,222 / 10,569,418 gas. | Removed the misleading gas accounting and assertion from `test/FrenRenderer.t.sol`. Added `script/check_launch_gas.py` and test-only `test/LaunchGasFactory.sol`: one local Anvil CREATE2 transaction, all launch-3 initcodes in calldata, receipt gas checked below 95% of 2^24 and above the code-deposit floor. The script checks the resulting runtime bounds, admission scan and all seven stored addresses. It needs only Python's standard library and existing Foundry tools, and contacts only its own private node. README now distinguishes this rehearsal from the deployment service's actual factory simulation. |
| `9ed0d517`: expensive metadata | Reproduced: a scratch direct `pendingURI(1)` call used 25,486,989 gas; the reference used 25,494,220 in this build. A staticcall capped at 25M failed. This is an integration limit, not a chunk regression. | Added `test_MetadataFitsThirtyMillionGas` with explicit 30M gas staticcalls for the audit's `tokenURI(1, 0xbd59c, 42)` and `pendingURI(1)` samples and byte-for-byte comparison with the reference. README documents the approximately 25.5M pending cost and insufficient 25M allowance. Preserved the requested art and output instead of redesigning rendering. An actual consumer/RPC budget must include its call overhead; the samples are not a universal gas upper bound. |
| `28171c3c`: stale constructor NatSpec | Reproduced: the constructor only assigns seven immutable addresses; `_entry` performs authentication when reading. | Corrected the header in `src/FrenRenderer.sol` and the same template in `script/art/derive_renderer.py`. Strengthened `test_DeploysWithoutTheEarlierChunks`: a factory deploys chunks 5–7 then the renderer via CREATE2, asserts all seven arguments and predictions, verifies absent earlier code, and checks `BadArt` on both metadata reads. |
| `f3604b25`: unused size table | Reproduced: `rg CHUNK_SIZES src` finds only the definition; `_entry` checks code hashes and read bounds, not the size table. | Clarified the actual behavior in README. The explicit task prohibition on changing `FrenArtIndex` takes precedence over correcting its generated comment; the index and generator remain unchanged. Existing wrong/swapped-art tests and reference rendering tests check the hash-based behavior. |
| `184911f5`: renderer missing from admission scan | Reproduced: the original admission test only iterated the seven chunks. | Added `test_RendererPassesTheAdmissionScan`, sharing the protected harness's PUSH-aware forbidden-opcode scan and nonempty/EIP-170 bounds with the chunk test. The exact four factory-deployed applications are also scanned in the fresh-chain test and receipt script. |
| `adef9759`: absent frens consumer | Reproduced on Ethereum: the README address returned `0x` code and nonce zero on 2026-10-07. | Removed the unsupported deployment/owner-control claims in README, marked the consumer unverified and documented the required interfaces. No substitute address or consumer deployment was invented. Existing reference equivalence tests cover local output compatibility; a deployed consumer remains an integration check for the requester. |
| `102e0b23`: review coverage | This is a coverage statement, not a defect to fix. Independently read the renderer, index, chunk constructors/generator, reference read path, repository tests and supplied protected/security references. | Verified the four earlier chunks through the mainnet fork reference-rendering test. The application has no funds, custody, mutable roles, proxy or external-call execution surface. Codehash checks precede each art copy; framed reads preserve chunk 7's PUSH32 encoding. No unrelated token, administration or security mechanisms were added. |

No actionable finding was dismissed as non-reproducible. The metadata budget and consumer deployment remain
documented integration limitations; the size-table source comment remains only because the brief forbids editing
that file. No mainnet transactions were sent and no wallet keys were read.

## Validation

Validation uses the repository's existing configuration (solc 0.8.26, optimizer 200 runs, via IR, Cancun bytecode,
no metadata hash) and Foundry 1.8.5. The local receipt check uses Anvil Prague with the per-transaction cap enabled.
Slither and Mythril were not run. The deployment service must independently simulate its own factory overhead,
signed deployment bytes and policy gas ceiling.

Additional checks performed:

- `forge build`: passed with the existing configuration (existing renderer lint warnings remain).
- `forge test`: 9 passed, 0 failed, 2 optional fork suites skipped with an empty environment.
- The supplied `Contracts.protected.t.sol`, copied into scratch and given the exact four initcodes and predicted
  CREATE2 addresses, passed its constructor, reference, runtime-size and forbidden-opcode checks.
- Mainnet `test/OnChainChunks.fork.t.sol` passed against the four supplied addresses. Their code hashes match
  `FrenArtIndex.CHUNK_HASHES`; runtime sizes are 24,001 / 24,139 / 23,479 / 21,187 bytes.
- `python3 script/check_launch_gas.py`: passed, **14,179,144 gas**, below the 15,938,355 limit (5% below 2^24).
  Runtimes for chunks 5 / 6 / 7 / renderer are
  19,403 / 21,405 / 8,944 / 14,096 bytes. A negative run with a 13M transaction limit failed as expected.
- The renderer derivation script was exercised in a temporary directory using the vendored reference; it emits
  the corrected read-time validation comment.
- `git diff --check` passed; the art chunks, index and protected build/dependency files have no changes.
