//! weaver — Direct Indexer Payment agreements on The Graph.
//!
//! DIPS settles through `RecurringCollector`, not through the query-fee path. An agreement is
//! signed off-chain by the payer (or stored on-chain as an offer), accepted by the data service it
//! was issued to, and collected against on a bounded cadence. No gateway is involved.

// `alloy-primitives` 0.8 deprecates `Signature` in favour of `PrimitiveSignature`, but
// `alloy-signer` 0.5's `sign_hash_sync` still returns the old type, so using the new one does not
// compile. Scoped here rather than papered over per-line: it is a transitional skew in a
// dependency and should be removed when alloy-signer catches up.
#![allow(deprecated)]

pub mod rca;
pub use rca::{authorization_proof_digest, domain_separator, Rca};
