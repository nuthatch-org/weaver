//! `weaver` — build, hash, sign and check Direct Indexer Payment agreements.
//!
//! DIPS settles through `RecurringCollector`. An agreement is signed off-chain by the payer,
//! accepted by the data service it was issued to, and collected on a bounded cadence. No gateway.

// See lib.rs: alloy-signer 0.5 still returns the type alloy-primitives 0.8 deprecates.
#![allow(deprecated)]

use std::str::FromStr;

use alloy_primitives::{hex, Address, Signature};
use alloy_signer::SignerSync;
use alloy_signer_local::PrivateKeySigner;
use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use weaver::Rca;

/// Canonical deployments, read from `graphprotocol/contracts` and confirmed on chain 2026-08-29.
const SEPOLIA_COLLECTOR: &str = "0x0b18befc60455121ad66ae6e4a647955fcde3900";
const MAINNET_COLLECTOR: &str = "0xff0dc7310fbfbcc2524dae230cd4f34727eb84ee";

#[derive(Parser)]
#[command(about = "Direct Indexer Payment agreements on The Graph", version)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Print a starter agreement to edit.
    Template,
    /// Show the EIP-712 digest a payer would sign.
    Hash {
        #[arg(long)]
        rca: std::path::PathBuf,
        #[command(flatten)]
        net: Net,
    },
    /// Sign an agreement as the payer.
    Sign {
        #[arg(long)]
        rca: std::path::PathBuf,
        /// File holding the payer key, hex. A file rather than a flag: argv is world-readable on
        /// Linux via /proc.
        #[arg(long)]
        key: std::path::PathBuf,
        #[command(flatten)]
        net: Net,
    },
    /// Produce the proof `authorizeSigner()` demands.
    ///
    /// Run this once per key, before signing anything. A payer signing their own agreement is
    /// rejected until they have authorized their own key. See the README.
    AuthorizeProof {
        /// The key being authorized. It also signs the proof.
        #[arg(long)]
        key: std::path::PathBuf,
        /// The account that will send the `authorizeSigner` transaction. Usually the same address
        /// as the key, which is the part that surprises people.
        #[arg(long)]
        authorizer: String,
        /// Unix seconds. The contract requires it to be in the future.
        #[arg(long)]
        deadline: u64,
        #[command(flatten)]
        net: Net,
    },
    /// Recover the signer, and say whether it is the payer the agreement names.
    Verify {
        #[arg(long)]
        rca: std::path::PathBuf,
        #[arg(long)]
        signature: String,
        #[command(flatten)]
        net: Net,
    },
}

#[derive(clap::Args)]
struct Net {
    /// `sepolia` (default) or `mainnet`.
    #[arg(long, default_value = "sepolia")]
    network: String,
}

impl Net {
    fn resolve(&self) -> Result<(u64, Address)> {
        match self.network.as_str() {
            "sepolia" => Ok((421_614, Address::from_str(SEPOLIA_COLLECTOR)?)),
            "mainnet" => Ok((42_161, Address::from_str(MAINNET_COLLECTOR)?)),
            other => anyhow::bail!("unknown network {other}; use sepolia or mainnet"),
        }
    }
}

fn load(path: &std::path::Path) -> Result<Rca> {
    let raw =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    serde_json::from_str(&raw).context("parsing the agreement")
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::Template => {
            println!("{}", include_str!("../examples/agreement.json").trim());
        }
        Cmd::Hash { rca, net } => {
            let (chain, collector) = net.resolve()?;
            let rca = load(&rca)?;
            println!("chain      {chain}");
            println!("collector  {collector}");
            println!("digest     {:#x}", rca.digest(chain, collector));
        }
        Cmd::Sign { rca, key, net } => {
            let (chain, collector) = net.resolve()?;
            let rca = load(&rca)?;
            let signer = PrivateKeySigner::from_str(std::fs::read_to_string(&key)?.trim())
                .context("parsing the key file")?;

            // Refuse rather than produce a signature the contract will reject. `accept()` recovers
            // and compares against `rca.payer`; a mismatch reverts with nothing useful in it.
            if signer.address() != rca.payer {
                anyhow::bail!(
                    "this key is {}, but the agreement names {} as the payer.\n\
                     accept() recovers the signature and compares it to `payer`, so this would \
                     revert on chain with no useful message.",
                    signer.address(),
                    rca.payer
                );
            }

            let sig = rca.sign(&signer, chain, collector)?;
            println!("signer     {}", signer.address());
            println!("digest     {:#x}", rca.digest(chain, collector));
            println!("signature  0x{}", hex::encode(sig.as_bytes()));
        }
        Cmd::AuthorizeProof {
            key,
            authorizer,
            deadline,
            net,
        } => {
            let (chain, collector) = net.resolve()?;
            let signer = PrivateKeySigner::from_str(std::fs::read_to_string(&key)?.trim())
                .context("parsing the key file")?;
            let authorizer = Address::from_str(&authorizer)?;
            let digest = weaver::authorization_proof_digest(
                chain,
                collector,
                alloy_primitives::U256::from(deadline),
                authorizer,
            );
            let sig = signer.sign_hash_sync(&digest)?;
            let proof = hex::encode(sig.as_bytes());

            println!("signer      {}", signer.address());
            println!("authorizer  {authorizer}");
            println!("deadline    {deadline}");
            println!("proof       0x{proof}");
            println!();
            println!("Send from {authorizer}:");
            println!("  cast send {collector} \\");
            println!("    'authorizeSigner(address,uint256,bytes)' \\");
            println!("    {} {deadline} 0x{proof}", signer.address());
        }
        Cmd::Verify {
            rca,
            signature,
            net,
        } => {
            let (chain, collector) = net.resolve()?;
            let rca = load(&rca)?;
            let bytes = hex::decode(signature.trim_start_matches("0x"))?;
            let sig = Signature::try_from(bytes.as_slice()).context("parsing the signature")?;
            let recovered = rca.recover(&sig, chain, collector)?;

            println!("recovered  {recovered}");
            println!("payer      {}", rca.payer);
            if recovered == rca.payer {
                println!("result     OK - accept() will authorise this");
            } else {
                println!("result     MISMATCH - accept() will revert");
                std::process::exit(1);
            }
        }
    }
    Ok(())
}
