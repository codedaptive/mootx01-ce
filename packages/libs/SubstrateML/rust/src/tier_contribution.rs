// tier_contribution.rs
//
// Tier contribution fingerprint per cookbook § 12.3. Mirror of
// glref-swift-TierContributionFingerprint.swift.
//
// Each contribution is a 64-byte canonical wire payload:
//   bytes 0..15   estate UUID (16 bytes)
//   bytes 16..19  pairing case (u32 BE)
//   bytes 20..23  row count (u32 BE)
//   bytes 24..55  OR-reduced fingerprint (32 bytes)
//   bytes 56..63  HLC packed (u64 BE)
//
// This layer emits the bare 64-byte payload — it neither checksums
// nor signs. Authenticity is a federation-egress concern, not a
// substrate one: the originating estate signs the outbound payload
// and encrypts it to the recipient scope at the share point
// (sign-then-encrypt-to-scope, DECISION_FEDERATION_SHARING_MODEL).
// That signature is ECDSA P-256 (ADR-013, EE FIPS requirement) and
// is built with the federation transport in v1.1; nothing signs
// this payload before then.

use substrate_types::hlc::HLC;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_kernel::kernel::PortableKernel;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FederationCase {
    Household = 1,
    Fleet     = 2,
    Industry  = 3,
}

impl FederationCase {
    pub fn raw(&self) -> u32 { *self as u32 }
    pub fn from_raw(v: u32) -> Option<Self> {
        match v {
            1 => Some(FederationCase::Household),
            2 => Some(FederationCase::Fleet),
            3 => Some(FederationCase::Industry),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TierContribution {
    pub estate_uuid: [u8; 16],
    pub federation_case: FederationCase,
    pub row_count: u32,
    pub aggregate: Fingerprint256,
    pub hlc: HLC,
}

pub struct TierContributionFingerprint;

impl TierContributionFingerprint {
    /// Build a contribution by OR-reducing a slice of shareable
    /// fingerprints (caller must have computed them under the
    /// pairing's shared hyperplane family).
    ///
    /// Routes the OR-reduction through `PortableKernel::for_current_platform`
    /// so that runtime federation work amortizes through the
    /// platform's best available SIMD backend. The cookbook
    /// §12.3 mathematical definition is preserved (commutative,
    /// associative, idempotent OR over the input cohort); the
    /// kernel layer just chooses how to execute it.
    pub fn build(estate_uuid: [u8; 16],
                 federation_case: FederationCase,
                 shareable: &[Fingerprint256],
                 hlc: HLC) -> TierContribution {
        let kernel = PortableKernel::for_current_platform();
        let aggregate = kernel.or_reduce_256(shareable);
        TierContribution {
            estate_uuid,
            federation_case,
            row_count: shareable.len() as u32,
            aggregate,
            hlc,
        }
    }

    /// Serialize to the 64-byte canonical wire format.
    pub fn encode(contrib: &TierContribution) -> [u8; 64] {
        let mut out = [0_u8; 64];
        out[0..16].copy_from_slice(&contrib.estate_uuid);
        out[16..20].copy_from_slice(&contrib.federation_case.raw().to_be_bytes());
        out[20..24].copy_from_slice(&contrib.row_count.to_be_bytes());
        out[24..32].copy_from_slice(&contrib.aggregate.block0.to_be_bytes());
        out[32..40].copy_from_slice(&contrib.aggregate.block1.to_be_bytes());
        out[40..48].copy_from_slice(&contrib.aggregate.block2.to_be_bytes());
        out[48..56].copy_from_slice(&contrib.aggregate.block3.to_be_bytes());
        out[56..64].copy_from_slice(&contrib.hlc.packed().to_be_bytes());
        out
    }

    /// Deserialize from the 64-byte canonical wire format.
    pub fn decode(bytes: &[u8]) -> Option<TierContribution> {
        if bytes.len() != 64 { return None; }
        let mut estate_uuid = [0_u8; 16];
        estate_uuid.copy_from_slice(&bytes[0..16]);

        let case_raw = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
        let federation_case = FederationCase::from_raw(case_raw)?;
        let row_count = u32::from_be_bytes(bytes[20..24].try_into().ok()?);

        let aggregate = Fingerprint256 {
            block0: u64::from_be_bytes(bytes[24..32].try_into().ok()?),
            block1: u64::from_be_bytes(bytes[32..40].try_into().ok()?),
            block2: u64::from_be_bytes(bytes[40..48].try_into().ok()?),
            block3: u64::from_be_bytes(bytes[48..56].try_into().ok()?),
        };
        let hlc_packed = u64::from_be_bytes(bytes[56..64].try_into().ok()?);
        let hlc = HLC::from_packed(hlc_packed);

        Some(TierContribution {
            estate_uuid, federation_case, row_count, aggregate, hlc,
        })
    }
}
