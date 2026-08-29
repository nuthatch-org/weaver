# weaver

**Direct Indexer Payment agreements on The Graph.**

DIPS settles through `RecurringCollector`, not through the query-fee path. A payer signs a
Recurring Collection Agreement off-chain (or stores an offer on-chain), the data service the
agreement was issued to calls `accept()`, and collection happens on a bounded cadence. **No gateway
is involved at any point** — a thing the roadmap and its source report both got wrong, and which
this repo exists partly to demonstrate.

## The correctness bar

Getting an EIP-712 hash wrong produces a signature that is perfectly valid and entirely useless:
the contract recovers a different address, reverts, and tells you nothing. You can lose a day to it.

So the hashing is checked against **the hash the deployed contract computes for the same
agreement**, not against a reading of the spec:

```
digest     0x0aa74aad34109dd3b276e6258b02bec0ed0a20e4d1f5e5d414ead514dd3428b1
```

That value came from `hashRCA()` on `RecurringCollector` at
`0x0b18befc60455121ad66ae6e4a647955fcde3900` (Arbitrum Sepolia), and the test asserts equality.
It has been mutation-tested twice: inlining the `bytes metadata` instead of hashing it, and
swapping two adjacent same-width fields, each make it fail.

## Use

```sh
weaver template > agreement.json          # a starter to edit
weaver hash   --rca agreement.json        # what the payer will sign
weaver sign   --rca agreement.json --key payer.key
weaver verify --rca agreement.json --signature 0x…
```

`sign` refuses when the key is not the payer the agreement names, because `accept()` recovers the
signature and compares it to `payer`, and the on-chain failure carries nothing useful.

`verify` exits non-zero on a mismatch, so tampering is caught before a transaction is spent:

```
recovered  0xE07ae1d73C98E4d9786F450e744Bd5A33a5f8989
payer      0xa56237DEA9E56b83b73a410CfE2539C38F32e854
result     MISMATCH - accept() will revert
```

Keys are read from a **file**, never a flag: argv is world-readable on Linux via `/proc`.

## Deployments

| | Arbitrum One | Arbitrum Sepolia |
|---|---|---|
| RecurringCollector | `0xff0dc7310fbfbcc2524dae230cd4f34727eb84ee` | `0x0b18befc60455121ad66ae6e4a647955fcde3900` |

Both confirmed to hold bytecode on 2026-08-29. **The whole path is exercisable on Sepolia**, where
gas and GRT are free — which is the point, because on Arbitrum One the DIPS indexing-agreement
allocation is currently zero.

## What is not here

Broadcasting. `accept()`, `collect()` and `cancel()` are transactions a data service or an indexer
sends with their own key; weaver builds and checks the thing that goes into them and deliberately
stops short of holding anyone's funds.

Apache-2.0.
