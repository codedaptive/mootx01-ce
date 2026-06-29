// src/primitives/registry.rs
//
// Primitive registry. Mirrors PrimitiveRegistry.swift in the
// Swift harness.

use crate::harness::vector_file::VectorFile;
use crate::primitives::anomaly::AnomalyPrimitive;
use crate::primitives::association_rule_mining::AssociationRuleMiningPrimitive;
use crate::primitives::formal_concept_analysis::FormalConceptAnalysisPrimitive;
use crate::primitives::audit_log_fold::AuditLogFoldPrimitive;
use crate::primitives::bit_field_masked_equals::BitFieldMaskedEqualsPrimitive;
use crate::primitives::bitwise::BitwisePrimitive;
use crate::primitives::bradley_terry::BradleyTerryPrimitive;
use crate::primitives::fft::FFTPrimitive;
use crate::primitives::fingerprint::FingerprintPrimitive;
use crate::primitives::hamming::HammingPrimitive;
use crate::primitives::hamming_nn::HammingNNPrimitive;
use crate::primitives::hlc::HLCPrimitive;
use crate::primitives::info_theory::InfoTheoryPrimitive;
use crate::primitives::lattice::LatticePrimitive;
use crate::primitives::matrix_decay::MatrixDecayPrimitive;
use crate::primitives::merkle_commitment::MerkleCommitmentPrimitive;
use crate::primitives::eigenvalue_centrality::EigenvalueCentralityPrimitive;
use crate::primitives::moment_summary::MomentSummaryPrimitive;
use crate::primitives::field_presence_matrix_f::FieldPresenceMatrixFPrimitive;
use crate::primitives::fnv::FNVPrimitive;
use crate::primitives::nmf::NMFPrimitive;
use crate::primitives::or_reduce::ORReducePrimitive;
use crate::primitives::pairing_handshake::PairingHandshakePrimitive;
use crate::primitives::partial_state_recall::PartialStateRecallPrimitive;
use crate::primitives::sampling::SamplingPrimitive;
use crate::primitives::shingle_similarity::ShingleSimilarityPrimitive;
use crate::primitives::simhash::SimHashPrimitive;
use crate::primitives::temporal_compression::TemporalCompressionPrimitive;
use crate::primitives::tier_contribution::TierContributionPrimitive;

pub struct PrimitiveDescriptor {
    pub name: &'static str,
    pub cookbook_section: &'static str,
    pub reference_file: &'static str,
    pub generate: fn(u64) -> Result<VectorFile, Box<dyn std::error::Error>>,
    pub validate: fn(&VectorFile) -> Result<ValidationResult, Box<dyn std::error::Error>>,
}

pub struct ValidationResult {
    pub passed: bool,
    pub case_results: Vec<CaseResult>,
    pub crc_expected: u32,
    pub crc_actual: u32,
}

pub struct CaseResult {
    pub id: String,
    pub passed: bool,
    pub diagnostic: Option<String>,
}

pub fn all_primitives() -> Vec<PrimitiveDescriptor> {
    vec![
        SimHashPrimitive::descriptor(),
        AnomalyPrimitive::descriptor(),
        AssociationRuleMiningPrimitive::descriptor(),
        FormalConceptAnalysisPrimitive::descriptor(),
        HammingPrimitive::descriptor(),
        ORReducePrimitive::descriptor(),
        BitwisePrimitive::descriptor(),
        HLCPrimitive::descriptor(),
        FingerprintPrimitive::descriptor(),
        LatticePrimitive::descriptor(),
        MatrixDecayPrimitive::descriptor(),
        EigenvalueCentralityPrimitive::descriptor(),
        MomentSummaryPrimitive::descriptor(),
        FieldPresenceMatrixFPrimitive::descriptor(),
        FNVPrimitive::descriptor(),
        BitFieldMaskedEqualsPrimitive::descriptor(),
        InfoTheoryPrimitive::descriptor(),
        BradleyTerryPrimitive::descriptor(),
        PartialStateRecallPrimitive::descriptor(),
        TemporalCompressionPrimitive::descriptor(),
        TierContributionPrimitive::descriptor(),
        FFTPrimitive::descriptor(),
        HammingNNPrimitive::descriptor(),
        PairingHandshakePrimitive::descriptor(),
        NMFPrimitive::descriptor(),
        AuditLogFoldPrimitive::descriptor(),
        SamplingPrimitive::descriptor(),
        ShingleSimilarityPrimitive::descriptor(),
        MerkleCommitmentPrimitive::descriptor(),
    ]
}

pub fn find_primitive(name: &str) -> Option<PrimitiveDescriptor> {
    all_primitives().into_iter().find(|p| p.name == name)
}
