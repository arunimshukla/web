---
layout: post
title: "Building blocks: sealring"
description: "The code that encrypts a private payment so that one recipient can read it, and finds that payment again among thousands of others."
date: 2026-09-11 15:00:00 +0200
author: "Aaryamann"
image: ../assets/posts/2026-09-11-building-blocks-sealring/hero.png
published: true
tags:
  - building-blocks
  - note-encryption
  - open-source
---

*Part of "Building blocks", the series on the primitives for confidential systems on Ethereum. The blocks live in [ethsystems/works](https://github.com/ethsystems/works).*

In a shielded pool, value lives in notes: private records of who holds what. A wallet finds its notes by scanning published encrypted records.

Note formats vary between protocols. Our PoCs kept rebuilding the code to format, encrypt, and scan them. We extracted that code into `sealring`, a library with a choice of cryptographic schemes and note formats.

Fixing the curve inside the library was never really an option. All our PoCs work with Ethereum in some capacity, so k256 was a given. Grumpkin showed up later when one of them needed to check a Note inside a circuit. Unfortunately, NIST's [transition draft](https://csrc.nist.gov/pubs/ir/8547/ipd) has 2035 as the end date for both of them. An institution running this has the same problem on a longer horizon, and must be able to swap the underlying cryptography out during an upgrade.

## Where the `seal` comes from in `sealring`

Sealing refers to the encryption of the Note. 

The sender makes a throwaway keypair and combines it with the recipient's public key into a shared secret. 
From that secret it derives a key, a nonce and a commit tag, encrypts the note, and publishes the envelope. 
Only the recipient can redo that combination. 
Key derivation also mixes in the suite identifier and the application domain, so a different curve or a different application cannot open the same note.

To open an envelope, the wallet derives that shared secret with its own secret key. 
Key derivation binds the recipient key, the suite identifier and the domain tag. 
The wallet checks the commit tag before attempting decryption.

This design is pretty standard, but `sealring` makes it easier to bring your own Note format, choose what scheme is used to generate the shared secret, and decide the encoding/decoding scheme as well. It does not lock you into a specific format dictated by popular libraries.

![The seal and open flow. A sender combines a throwaway keypair with the recipient's public key into a shared secret, derives a key, nonce, and commit tag from it, and encrypts the note. Every wallet that sees the published envelope repeats the same combination with its own secret key, recomputes the commit tag, and compares it before it ever runs the AEAD. A mismatch is skipped; a match is decrypted.](../assets/posts/2026-09-11-building-blocks-sealring/protocol-flow.svg)

*Figure 1: seal, publish, and the commit check*

## The costs of Scanning

The cost of processing an envelope is directly proportional to the size of the set it belongs to. One can reduce that cost in two ways: fewer expensive operations per Note, and more Notes processed at once. `sealring` does both.

Decrypting every entry costs one decapsulation per envelope. On k256, the resulting curve point must be converted from projective to affine coordinates. That conversion requires a field inversion (finding the mathematical inverse of a number inside a finite field), which the scan path shares across a batch.

The scan path moves fixed 64-envelope chunks through a batched version of that conversion. On k256, one inversion covers the whole chunk, using [Montgomery's trick](https://www.johndcook.com/blog/2026/01/14/montgomerys-trick/): multiply the 64 values together, invert the product once, then recover each value's inverse from it. The parallel version spreads whole chunks across multiple CPU cores at once.

![A chunk of 64 envelopes moving through the scan path. Each envelope's ephemeral key is decapsulated against the recipient's secret key. The resulting points are converted from projective to affine coordinates as one batch. One field inversion is amortized across the whole chunk.](../assets/posts/2026-09-11-building-blocks-sealring/scan-path.svg)

*Figure 2: On k256, one field inversion is shared across 64 envelopes. Each envelope still needs decapsulation.*

| adapter | naive open loop | scan | scan_parallel |
|---|---|---|---|
| x25519 | 20.0 ms | 20.2 ms | 2.22 ms |
| k256 | 22.6 ms | 21.2 ms | 2.40 ms |

*1024 envelopes, 1% hit rate, 48-byte notes, run on an M4 Pro with 14 cores and 48 GB of memory. The benchmark is [`benches/scan.rs`](https://github.com/ethsystems/works/blob/e5593dc/crates/sealring/benches/scan.rs) at revision `e5593dc`.*

Batching alone is worth about 6% on k256. The parallel path accounts for most of the gain.

Batching does not remove the decapsulation itself: one scalar multiplication per envelope. On k256 the crate already splits it into two half-size multiplications using the curve's endomorphism (GLV). x25519 has no such endomorphism. Grumpkin has one, but arkworks has not wired it up; the one [attempt](https://github.com/arkworks-rs/algebra/pull/778) stalled.

Zcash's own scanning algorithm is similar, defined in section 4.22 of the [Zcash protocol specification](https://zips.z.cash/protocol/protocol.pdf): trial-decrypt every output, one at a time, with no shortcut defined around that loop. `sealring`'s batching and parallelism operate on the same primitive operation Zcash's algorithm calls once per output. They lower the constant factor per call; the one-decapsulation-per-output floor is the same in both. A curve swap changes how much each decapsulation costs.

[ERC-5564](https://eips.ethereum.org/EIPS/eip-5564) stealth addresses, on the other hand, append a one-byte "identifier" to the envelope. This identifier makes it cheaper to verify if a Note belongs to you, trading off a few bits of security in the process.

### Privacy properties of Scanning

An observer of the bulletin board sees an "envelope" of data:

1. a throwaway public key
2. a commit tag
3. the Note

The note carries no sender signature.

## Composability

You pick two things: the curve and the note format.

The `Kem` trait covers the curve: k256, x25519 and grumpkin are available out of the box.
It is responsible for encapsulation and decapsulation, returning an opaque shared secret. One byte in the envelope header records which scheme sealed it.

The `Domain` trait covers the note format, keeping envelopes from different applications separated by a tag. 

Five of our PoCs replaced their hand-written note encryption with `sealring`: [private transfers](/writeups/building-private-transfers-on-ethereum-with-shielded-pools/), [hardened shielded pools](/writeups/exploring-hardened-shielded-pools/), [in-pool compliance](/writeups/building-compliant-shielded-pools-on-ethereum/), [private bonds](/writeups/building-private-bonds-on-ethereum/) and [disbursement rails](/writeups/resilient-disbursement-rails/). Disbursement rails binds the destination relay's id into the authenticated data. Using `sealring` there looks like:

```rust
let envelope =
    sealring::seal::<X25519, VoucherDomain>(relay_pk, &note, &relay_id, &mut rand::rng())?;
```

![Sealring's fixed core at the center, seal, open, and scan. On one side, the Kem trait with three curve adapters: k256, x25519, and grumpkin. On the other side, the Domain trait, instantiated differently by several PoCs, each with its own note format and domain tag.](../assets/posts/2026-09-11-building-blocks-sealring/composability.svg)

*Figure 3: one fixed core with two extension points. Several PoCs plug into it today.*

## Prior art

[RFC 9180](https://www.rfc-editor.org/info/rfc9180/) already standardizes the design: Hybrid Public Key Encryption. However, the APIs are shaped for one sender addressing one recipient, with no batch and no scan anywhere in the specification.

Its KEM registry covers three NIST curves (P-256, P-384, P-521) plus x25519 and x448. Neither k256 nor grumpkin is on the list. A Rust implementation that follows the registry closely, the [`hpke` crate](https://docs.rs/hpke/latest/hpke/), ships four of those five classical curves alongside post-quantum KEMs. We needed different curves, a scan path, and a Note format the application defines.

Gallant, Lambert, and Vanstone published the underlying mathematical optimizations for the elliptic curve operations involved in Scanning, in [Faster Point Multiplication on Elliptic Curves with Efficient Endomorphisms](https://www.iacr.org/archive/crypto2001/21390189.pdf).

## What it does not fix

Scanning still costs one decapsulation per envelope. Batching and parallelism cut the time spent on that work. There is no post-quantum adapter yet. Adding one would not require touching the core logic of the library. 

HSM Integration coming soon too, to better cater to existing deployments.

`sealring` has been reviewed internally. An external audit is pending.


`sealring` lives in [ethsystems/works](https://github.com/ethsystems/works), under MIT or Apache-2.0. The API is subject to change.

Retiring a curve means swapping that adapter. The keys and the Note format carry over.
