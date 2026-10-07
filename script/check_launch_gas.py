#!/usr/bin/env python3
"""Offline receipt-based launch 3 check. Requires only Python 3 and the installed Foundry tools."""
import http.client
import json
from pathlib import Path
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
TX_CAP = 1 << 24
LIMIT = TX_CAP * 95 // 100
EARLIER = [
    "0xa92dAcfF6d6fcC218ADe20eD24857376BD8eBE81",
    "0x9666A481e20F1dB59EEbD6c43D11Ae3505468c92",
    "0x71BdEB749b3ee428730eBB3E9b34B03A99D82356",
    "0x0C344484D960B8474a1EdcB5A5128e8D9C9F6B4d",
]


def word(n):
    return n.to_bytes(32, "big")


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True, cwd=ROOT).strip()


def keccak(data):
    return bytes.fromhex(cast("keccak", "0x" + data.hex())[2:])


def initcode(source, contract):
    artifact = json.loads((ROOT / "out" / source / (contract + ".json")).read_text())
    return bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))


def check(port):
    # Only the private node started below is used; no RPC environment variables or wallet keys.
    def rpc(method, params):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        try:
            conn.request("POST", "/", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}),
                         {"Content-Type": "application/json"})
            response = json.load(conn.getresponse())
        finally:
            conn.close()
        if "error" in response:
            raise RuntimeError(response["error"])
        return response["result"]

    for _ in range(100):
        try:
            assert int(rpc("eth_chainId", []), 16) == 31337
            break
        except (ConnectionError, OSError):
            time.sleep(0.1)
    else:
        raise RuntimeError("local Anvil did not start")

    sender = "0x000000000000000000000000000000000000beef"
    rpc("anvil_setBalance", [sender, hex(10**20)])

    def send(data, to=None):
        tx = {"from": sender, "data": "0x" + data.hex(), "gas": hex(LIMIT)}
        if to:
            tx["to"] = to
        tx_hash = rpc("eth_sendTransaction", [tx])
        receipt = None
        for _ in range(100):
            receipt = rpc("eth_getTransactionReceipt", [tx_hash])
            if receipt:
                break
            time.sleep(0.1)
        assert receipt and int(receipt["status"], 16) == 1, "local deployment reverted"
        return receipt

    factory = send(initcode("LaunchGasFactory.sol", "LaunchGasFactory"))["contractAddress"]
    codes = [initcode("FrenArtChunks.sol", f"FrenArtChunk{k}") for k in (5, 6, 7)]

    def predicted(i, code):
        return "0x" + keccak(b"\xff" + bytes.fromhex(factory[2:]) + word(i) + keccak(code))[-20:].hex()

    chunks = [predicted(i, code) for i, code in enumerate(codes)]
    args = b"".join(word(int(address, 16)) for address in EARLIER + chunks)
    codes.append(initcode("FrenRenderer.sol", "FrenRenderer") + args)
    addresses = chunks + [predicted(3, codes[3])]
    assert all(rpc("eth_getCode", [a, "latest"]) == "0x" for a in EARLIER)

    # ABI encoding of deploy(bytes[]): offsets within the array start after its length word.
    tails = [word(len(code)) + code + bytes(-len(code) % 32) for code in codes]
    offsets, cursor = [], 32 * len(codes)
    for tail in tails:
        offsets.append(word(cursor))
        cursor += len(tail)
    calldata = keccak(b"deploy(bytes[])")[:4] + word(32) + word(len(codes)) + b"".join(offsets + tails)
    receipt = send(calldata, factory)
    used = int(receipt["gasUsed"], 16)
    runtime_sizes = []
    for address in addresses:
        code = bytes.fromhex(rpc("eth_getCode", [address, "latest"])[2:])
        assert 0 < len(code) <= 24_576, "invalid application runtime size"
        runtime_sizes.append(len(code))
        i = 0
        while i < len(code):
            op = code[i]
            assert op not in (0xf2, 0xf4, 0xff), "forbidden application opcode"
            i += 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
    for k, expected in enumerate(EARLIER + chunks, 1):
        actual = rpc("eth_call", [{"to": addresses[3], "data": "0x" + keccak(f"chunk{k}()".encode())[:4].hex()}, "latest"])
        assert int(actual, 16) == int(expected, 16), "constructor argument order changed"
    # A gas meter omitting code deposit cannot pass this floor.
    assert sum(runtime_sizes) * 200 < used < LIMIT, (used, runtime_sizes)
    print(f"Launch 3 CREATE2 receipt: {used:,} gas; limit with 5% reserve: {LIMIT:,}; cap: {TX_CAP:,}")
    print(f"Runtime sizes (chunks 5, 6, 7, renderer): {runtime_sizes}")
    print("Actual deployment-service overhead and policy ceiling still require its simulation.")


def main():
    subprocess.run(["forge", "build", "--quiet"], cwd=ROOT, check=True)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    node = subprocess.Popen(["anvil", "--host", "127.0.0.1", "--port", str(port), "--chain-id", "31337",
                             "--accounts", "0", "--auto-impersonate", "--hardfork", "prague",
                             "--enable-tx-gas-limit", "--quiet"], stdout=subprocess.DEVNULL)
    try:
        check(port)
    finally:
        node.terminate()
        node.wait(timeout=10)


if __name__ == "__main__":
    main()
