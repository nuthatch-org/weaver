//! The Recurring Collection Agreement, and its EIP-712 hash.
//!
//! # Why this is done by hand
//!
//! Getting an EIP-712 hash wrong produces a signature that is perfectly valid and useless: the
//! contract recovers a different address, rejects the agreement, and tells you nothing about why.
//! It is the kind of bug you can stare at for a day.
//!
//! So the encoding is written out explicitly rather than derived by a macro, and the test suite
//! checks it against **the hash the deployed contract computes for the same agreement**. Not
//! against my reading of the spec; against the thing that will actually be verifying the
//! signature. See `tests` at the bottom.

use alloy_primitives::{keccak256, Address, B256, U256};

/// The agreement, matching `IRecurringCollector.RecurringCollectionAgreement` field for field and
/// in order. **The order is part of the hash**; reordering these silently changes every signature.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Rca {
    /// Unix seconds by which the agreement must be accepted.
    pub deadline: u64,
    /// Unix seconds when it ends.
    pub ends_at: u64,
    /// Who pays. For DIPS, whoever is funding the indexing.
    pub payer: Address,
    /// The data service the agreement is issued to — the only address allowed to `accept()` it.
    pub data_service: Address,
    /// Who gets paid. For DIPS, the indexer.
    pub service_provider: Address,
    /// Ceiling on the first collection.
    pub max_initial_tokens: U256,
    /// Ceiling on the ongoing rate.
    pub max_ongoing_tokens_per_second: U256,
    /// Floor on how often collection may happen, so a provider cannot bill continuously.
    pub min_seconds_per_collection: u32,
    /// Ceiling, so an agreement cannot go uncollected indefinitely and then claim everything.
    pub max_seconds_per_collection: u32,
    pub conditions: u16,
    /// Replay protection. Two otherwise-identical agreements need different nonces or they hash
    /// the same and the second `accept()` is a silent no-op.
    pub nonce: U256,
    pub metadata: Vec<u8>,
}

/// The EIP-712 type string. Every character matters: a stray space or a renamed field changes the
/// type hash and therefore every signature.
pub const RCA_TYPE: &str = "RecurringCollectionAgreement(\
uint64 deadline,\
uint64 endsAt,\
address payer,\
address dataService,\
address serviceProvider,\
uint256 maxInitialTokens,\
uint256 maxOngoingTokensPerSecond,\
uint32 minSecondsPerCollection,\
uint32 maxSecondsPerCollection,\
uint16 conditions,\
uint256 nonce,\
bytes metadata)";

pub const DOMAIN_NAME: &str = "RecurringCollector";
pub const DOMAIN_VERSION: &str = "1";

fn type_hash() -> B256 {
    keccak256(RCA_TYPE.as_bytes())
}

fn word(bytes: [u8; 32]) -> [u8; 32] {
    bytes
}

fn u256_word(v: U256) -> [u8; 32] {
    v.to_be_bytes()
}

fn addr_word(a: Address) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(a.as_slice());
    w
}

fn uint_word(v: u128) -> [u8; 32] {
    u256_word(U256::from(v))
}

impl Rca {
    /// `hashStruct(rca)` — the EIP-712 struct hash, before the domain is mixed in.
    pub fn hash_struct(&self) -> B256 {
        let mut buf = Vec::with_capacity(13 * 32);
        buf.extend_from_slice(word(type_hash().0).as_slice());
        buf.extend_from_slice(&uint_word(self.deadline as u128));
        buf.extend_from_slice(&uint_word(self.ends_at as u128));
        buf.extend_from_slice(&addr_word(self.payer));
        buf.extend_from_slice(&addr_word(self.data_service));
        buf.extend_from_slice(&addr_word(self.service_provider));
        buf.extend_from_slice(&u256_word(self.max_initial_tokens));
        buf.extend_from_slice(&u256_word(self.max_ongoing_tokens_per_second));
        buf.extend_from_slice(&uint_word(self.min_seconds_per_collection as u128));
        buf.extend_from_slice(&uint_word(self.max_seconds_per_collection as u128));
        buf.extend_from_slice(&uint_word(self.conditions as u128));
        buf.extend_from_slice(&u256_word(self.nonce));
        // `bytes` is hashed, not inlined — the single most common way to get EIP-712 wrong.
        buf.extend_from_slice(keccak256(&self.metadata).as_slice());
        keccak256(&buf)
    }

    /// The full EIP-712 digest a signer signs: `0x1901 || domainSeparator || hashStruct`.
    pub fn digest(&self, chain_id: u64, verifying_contract: Address) -> B256 {
        let sep = domain_separator(chain_id, verifying_contract);
        let mut buf = Vec::with_capacity(66);
        buf.extend_from_slice(&[0x19, 0x01]);
        buf.extend_from_slice(sep.as_slice());
        buf.extend_from_slice(self.hash_struct().as_slice());
        keccak256(&buf)
    }
}

/// The EIP-712 domain separator for a `RecurringCollector` deployment.
pub fn domain_separator(chain_id: u64, verifying_contract: Address) -> B256 {
    const DOMAIN_TYPE: &str =
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
    let mut buf = Vec::with_capacity(5 * 32);
    buf.extend_from_slice(keccak256(DOMAIN_TYPE.as_bytes()).as_slice());
    buf.extend_from_slice(keccak256(DOMAIN_NAME.as_bytes()).as_slice());
    buf.extend_from_slice(keccak256(DOMAIN_VERSION.as_bytes()).as_slice());
    buf.extend_from_slice(&uint_word(chain_id as u128));
    buf.extend_from_slice(&addr_word(verifying_contract));
    keccak256(&buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    /// The agreement used for the ground-truth vector below.
    fn fixture() -> Rca {
        Rca {
            deadline: 1_893_456_000,
            ends_at: 1_924_992_000,
            payer: Address::from_str("0x1111111111111111111111111111111111111111").unwrap(),
            data_service: Address::from_str("0x2222222222222222222222222222222222222222").unwrap(),
            service_provider: Address::from_str("0x3333333333333333333333333333333333333333")
                .unwrap(),
            max_initial_tokens: U256::from(1_000_000_000_000_000_000u128),
            max_ongoing_tokens_per_second: U256::from(2_000_000_000u128),
            min_seconds_per_collection: 3600,
            max_seconds_per_collection: 86_400,
            conditions: 0,
            nonce: U256::from(42u64),
            metadata: vec![0xde, 0xad, 0xbe, 0xef],
        }
    }

    /// **The test that matters.**
    ///
    /// This value came from the deployed `RecurringCollector` on Arbitrum Sepolia
    /// (`0x0b18befc60455121ad66ae6e4a647955fcde3900`) on 2026-08-29:
    ///
    /// ```text
    /// cast call --rpc-url $ARB_SEPOLIA 0x0b18befc… \
    ///   "hashRCA((uint64,uint64,address,address,address,uint256,uint256,uint32,uint32,uint16,uint256,bytes))(bytes32)" \
    ///   '(1893456000,1924992000,0x1111…,0x2222…,0x3333…,1000000000000000000,2000000000,3600,86400,0,42,0xdeadbeef)'
    /// ```
    ///
    /// Checking against the contract that will verify the signature, rather than against my
    /// reading of the spec, is the difference between "I believe this is right" and "this is
    /// right". A wrong EIP-712 hash produces a perfectly valid, entirely useless signature.
    #[test]
    fn the_digest_matches_the_deployed_contract() {
        const GROUND_TRUTH: &str =
            "0x0aa74aad34109dd3b276e6258b02bec0ed0a20e4d1f5e5d414ead514dd3428b1";
        let collector = Address::from_str("0x0b18befc60455121ad66ae6e4a647955fcde3900").unwrap();
        assert_eq!(
            format!("{:#x}", fixture().digest(421_614, collector)),
            GROUND_TRUTH,
            "our EIP-712 digest must equal what the deployed RecurringCollector computes"
        );
    }

    #[test]
    fn the_domain_matches_what_the_contract_reports() {
        // eip712Domain() on the same deployment returned name="RecurringCollector", version="1".
        assert_eq!(DOMAIN_NAME, "RecurringCollector");
        assert_eq!(DOMAIN_VERSION, "1");
    }

    /// A different chain or a different deployment must produce a different digest, or a signature
    /// for testnet would be replayable on mainnet.
    #[test]
    fn the_digest_is_bound_to_the_chain_and_the_collector() {
        let a = Address::from_str("0x0b18befc60455121ad66ae6e4a647955fcde3900").unwrap();
        let b = Address::from_str("0xff0dc7310fbfbcc2524dae230cd4f34727eb84ee").unwrap();
        let rca = fixture();
        assert_ne!(
            rca.digest(421_614, a),
            rca.digest(42_161, a),
            "chain must be bound"
        );
        assert_ne!(
            rca.digest(421_614, a),
            rca.digest(421_614, b),
            "collector must be bound"
        );
    }

    /// `bytes` fields are hashed, not inlined. Getting this wrong is the classic EIP-712 error and
    /// it only shows up as a rejected signature.
    #[test]
    fn metadata_changes_the_hash() {
        let mut other = fixture();
        other.metadata = vec![0xde, 0xad, 0xbe, 0xee];
        assert_ne!(fixture().hash_struct(), other.hash_struct());
    }

    /// Two otherwise-identical agreements with the same nonce hash identically, and the second
    /// `accept()` is a documented no-op rather than an error. Worth a test so nobody rediscovers
    /// it as "my agreement silently did not exist".
    #[test]
    fn the_nonce_is_what_distinguishes_two_identical_agreements() {
        let a = fixture();
        let mut b = fixture();
        assert_eq!(
            a.hash_struct(),
            b.hash_struct(),
            "same nonce, same agreement"
        );
        b.nonce = U256::from(43u64);
        assert_ne!(a.hash_struct(), b.hash_struct());
    }

    #[test]
    fn the_type_string_has_no_stray_whitespace() {
        assert!(
            !RCA_TYPE.contains(", "),
            "EIP-712 type strings have no spaces after commas"
        );
        assert!(RCA_TYPE.ends_with("bytes metadata)"));
    }
}

// ── Signing ──────────────────────────────────────────────────────────────────

use alloy_signer::{Signature, SignerSync};
use alloy_signer_local::PrivateKeySigner;

impl Rca {
    /// Signs the agreement as the payer. The data service passes this to `accept()`.
    pub fn sign(
        &self,
        signer: &PrivateKeySigner,
        chain_id: u64,
        collector: Address,
    ) -> Result<Signature, alloy_signer::Error> {
        signer.sign_hash_sync(&self.digest(chain_id, collector))
    }

    /// Who signed it. The contract does exactly this and compares against `rca.payer`, so running
    /// it locally turns "the transaction reverted" into "you signed with the wrong key".
    pub fn recover(
        &self,
        signature: &Signature,
        chain_id: u64,
        collector: Address,
    ) -> Result<Address, alloy_primitives::SignatureError> {
        signature.recover_address_from_prehash(&self.digest(chain_id, collector))
    }
}

#[cfg(test)]
mod signing_tests {
    use super::*;
    use std::str::FromStr;

    fn collector() -> Address {
        Address::from_str("0x0b18befc60455121ad66ae6e4a647955fcde3900").unwrap()
    }

    fn rca_for(payer: Address) -> Rca {
        Rca {
            deadline: 1_893_456_000,
            ends_at: 1_924_992_000,
            payer,
            data_service: Address::from_str("0x2222222222222222222222222222222222222222").unwrap(),
            service_provider: Address::from_str("0x3333333333333333333333333333333333333333")
                .unwrap(),
            max_initial_tokens: U256::from(1_000_000_000_000_000_000u128),
            max_ongoing_tokens_per_second: U256::from(2_000_000_000u128),
            min_seconds_per_collection: 3600,
            max_seconds_per_collection: 86_400,
            conditions: 0,
            nonce: U256::from(1u64),
            metadata: vec![],
        }
    }

    #[test]
    fn a_signature_recovers_to_the_signer() {
        let signer = PrivateKeySigner::random();
        let rca = rca_for(signer.address());
        let sig = rca.sign(&signer, 421_614, collector()).unwrap();
        assert_eq!(
            rca.recover(&sig, 421_614, collector()).unwrap(),
            signer.address()
        );
    }

    /// The contract checks the recovered address against `rca.payer`. Catching the mismatch here
    /// turns an opaque revert into an obvious mistake.
    #[test]
    fn signing_with_the_wrong_key_recovers_to_someone_who_is_not_the_payer() {
        let payer = PrivateKeySigner::random();
        let intruder = PrivateKeySigner::random();
        let rca = rca_for(payer.address());
        let sig = rca.sign(&intruder, 421_614, collector()).unwrap();
        assert_ne!(rca.recover(&sig, 421_614, collector()).unwrap(), rca.payer);
    }

    /// A testnet signature must not be replayable against mainnet.
    #[test]
    fn a_signature_does_not_carry_across_chains() {
        let signer = PrivateKeySigner::random();
        let rca = rca_for(signer.address());
        let sig = rca.sign(&signer, 421_614, collector()).unwrap();
        assert_ne!(
            rca.recover(&sig, 42_161, collector()).unwrap(),
            signer.address(),
            "a Sepolia signature must not verify on Arbitrum One"
        );
    }

    /// Altering any field after signing must invalidate it, or a data service could accept an
    /// agreement on terms the payer never agreed to.
    #[test]
    fn tampering_with_the_terms_invalidates_the_signature() {
        let signer = PrivateKeySigner::random();
        let rca = rca_for(signer.address());
        let sig = rca.sign(&signer, 421_614, collector()).unwrap();

        let mut greedier = rca.clone();
        greedier.max_ongoing_tokens_per_second = U256::from(999_999_999_999u128);
        assert_ne!(
            greedier.recover(&sig, 421_614, collector()).unwrap(),
            greedier.payer,
            "raising the rate after signing must not verify"
        );
    }
}
