// delta_feature_extractor.rs
//
// Delta feature analysis per DISTILLATION_MATH_DIFFUSION.md §6.
// Rust port of DeltaFeatureExtractor.swift. Parity conformance to be verified in Dp1.
//
// Analyzes an ordered sequence of (value, timestamp) observations for a
// single feature (REL, ENT, or NUM schema) and classifies the sequence's
// trajectory. Feeds Stage 2.5 of the distillation pipeline, rescuing
// CONVERGENT and MONOTONE features that fail the majority-vote threshold
// because no single value reaches df >= τ_maj.
//
// DeltaType classification:
//   STATIC      — all values identical; handled by Stage 2 majority vote
//   CONVERGENT  — categorical sequence converges to a stable terminal value
//   MONOTONE    — numerical sequence trends monotonically (all diffs same sign)
//   OSCILLATING — period-2 pattern detected (A→B→A→B); flag as unstable
//   DIVERGENT   — no classifiable pattern; drop
//
// Default decay lambdas: categorical = 0.5, numerical = 0.8 (from §2 type table).
//
// Timestamps are f64 Unix epoch seconds. Confidence = convergence_score × decay_lambda;
// full temporal weighting (C × w_temporal) requires TypedDecayWeighting and is
// applied upstream in DistillationPipeline.

/// Five-class trajectory label for a feature sequence.
/// String representation is uppercase ASCII, matching Swift DeltaType.rawValue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeltaType {
    Static,
    Convergent,
    Monotone,
    Oscillating,
    Divergent,
}

impl DeltaType {
    /// Returns the canonical uppercase string representation.
    /// Matches Swift `DeltaType.rawValue` exactly — required for Dp1 conformance.
    pub fn as_str(&self) -> &'static str {
        match self {
            DeltaType::Static => "STATIC",
            DeltaType::Convergent => "CONVERGENT",
            DeltaType::Monotone => "MONOTONE",
            DeltaType::Oscillating => "OSCILLATING",
            DeltaType::Divergent => "DIVERGENT",
        }
    }
}

impl std::fmt::Display for DeltaType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Output of a single delta feature analysis pass.
/// `slope` is Some only for MONOTONE sequences (average rate of change).
/// `confidence` is a simplified estimate; DistillationPipeline applies full
/// temporal weighting via TypedDecayWeighting before scoring.
#[derive(Debug, Clone, PartialEq)]
pub struct DeltaAnalysis {
    pub delta_type: DeltaType,
    /// Most recent value in the sequence (string-encoded for categorical;
    /// Display-formatted f64 for numerical).
    pub terminal_value: String,
    /// C = k / M where k = consecutive trailing observations matching terminal_value.
    /// 1.0 for STATIC; 0.0 for OSCILLATING and DIVERGENT.
    pub convergence_score: f32,
    /// Average rate of change across differences. Some only when delta_type == Monotone.
    pub slope: Option<f32>,
    /// Simplified confidence: convergence_score × decay_lambda.
    pub confidence: f32,
}

/// Pure-function namespace for delta feature extraction.
/// No state, no I/O. Mirrors Swift `enum DeltaFeatureExtractor` namespace pattern.
pub struct DeltaFeatureExtractor;

impl DeltaFeatureExtractor {
    /// Classify an ordered categorical sequence (REL.object, ENT.value).
    ///
    /// - `sequence`: (value, timestamp_epoch_seconds) pairs in chronological order.
    /// - `decay_lambda`: type-specific decay rate (default 0.5 for REL/ENT per §2).
    ///
    /// Detection order: STATIC → CONVERGENT → OSCILLATING → DIVERGENT.
    pub fn analyze_categorical(sequence: &[(String, f64)], decay_lambda: f32) -> DeltaAnalysis {
        let m = sequence.len();

        if m <= 1 {
            let terminal = sequence.first().map(|(v, _)| v.clone()).unwrap_or_default();
            return DeltaAnalysis {
                delta_type: DeltaType::Static,
                terminal_value: terminal,
                convergence_score: 1.0,
                slope: None,
                confidence: decay_lambda,
            };
        }

        // STATIC: all values identical.
        let first = &sequence[0].0;
        if sequence.iter().all(|(v, _)| v == first) {
            return DeltaAnalysis {
                delta_type: DeltaType::Static,
                terminal_value: first.clone(),
                convergence_score: 1.0,
                slope: None,
                confidence: decay_lambda,
            };
        }

        let terminal_value = sequence[m - 1].0.clone();

        // Convergence score: k = length of consecutive trailing run matching terminal.
        let mut k = 0usize;
        for (val, _) in sequence.iter().rev() {
            if val == &terminal_value {
                k += 1;
            } else {
                break;
            }
        }
        let convergence_score = k as f32 / m as f32;

        // CONVERGENT: terminal value holds for at least half the sequence.
        if convergence_score >= 0.5 {
            return DeltaAnalysis {
                delta_type: DeltaType::Convergent,
                terminal_value,
                convergence_score,
                slope: None,
                confidence: convergence_score * decay_lambda,
            };
        }

        // OSCILLATING: period-2 pattern on last 4 observations (A→B→A→B).
        if m >= 4 {
            let last4 = &sequence[m - 4..];
            let (a0, b0, a1, b1) = (&last4[0].0, &last4[1].0, &last4[2].0, &last4[3].0);
            if a0 == a1 && b0 == b1 && a0 != b0 {
                return DeltaAnalysis {
                    delta_type: DeltaType::Oscillating,
                    terminal_value,
                    convergence_score: 0.0,
                    slope: None,
                    confidence: 0.0,
                };
            }
        }

        // DIVERGENT: no classifiable pattern.
        DeltaAnalysis {
            delta_type: DeltaType::Divergent,
            terminal_value,
            convergence_score: 0.0,
            slope: None,
            confidence: 0.0,
        }
    }

    /// Classify an ordered numerical sequence (NUM.value).
    ///
    /// - `sequence`: (value, timestamp_epoch_seconds) pairs in chronological order.
    /// - `decay_lambda`: type-specific decay rate (default 0.8 for NUM per §2).
    ///
    /// Detection order: STATIC → MONOTONE → OSCILLATING → DIVERGENT.
    /// Slope = average of consecutive differences (f64→f32 cast).
    pub fn analyze_numerical(sequence: &[(f64, f64)], decay_lambda: f32) -> DeltaAnalysis {
        let m = sequence.len();

        if m <= 1 {
            let terminal = sequence
                .first()
                .map(|(v, _)| format!("{}", v))
                .unwrap_or_default();
            return DeltaAnalysis {
                delta_type: DeltaType::Static,
                terminal_value: terminal,
                convergence_score: 1.0,
                slope: None,
                confidence: decay_lambda,
            };
        }

        let terminal_value = format!("{}", sequence[m - 1].0);

        // Compute consecutive differences.
        let diffs: Vec<f64> = sequence.windows(2).map(|w| w[1].0 - w[0].0).collect();

        let positive = diffs.iter().filter(|&&d| d > 0.0).count();
        let negative = diffs.iter().filter(|&&d| d < 0.0).count();

        // STATIC: all values identical (all differences are zero).
        if positive == 0 && negative == 0 {
            return DeltaAnalysis {
                delta_type: DeltaType::Static,
                terminal_value,
                convergence_score: 1.0,
                slope: None,
                confidence: decay_lambda,
            };
        }

        // MONOTONE: all differences share the same sign (all up or all down).
        // Slope = average rate of change across the sequence.
        if positive == m - 1 || negative == m - 1 {
            let slope = (diffs.iter().sum::<f64>() / diffs.len() as f64) as f32;
            return DeltaAnalysis {
                delta_type: DeltaType::Monotone,
                terminal_value,
                convergence_score: 1.0,
                slope: Some(slope),
                confidence: decay_lambda,
            };
        }

        // OSCILLATING: alternating sign pattern on last 4 differences (±∓±).
        // Requires at least 5 observations (4 differences) to detect.
        if m >= 5 {
            let last4: Vec<f64> = diffs[diffs.len() - 4..].to_vec();
            let signs: Vec<i32> = last4
                .iter()
                .map(|&d| if d > 0.0 { 1 } else if d < 0.0 { -1 } else { 0 })
                .collect();
            // Strict alternation: no zero differences, each sign opposes the prior.
            if signs.iter().all(|&s| s != 0)
                && signs[0] == -signs[1]
                && signs[1] == -signs[2]
                && signs[2] == -signs[3]
            {
                return DeltaAnalysis {
                    delta_type: DeltaType::Oscillating,
                    terminal_value,
                    convergence_score: 0.0,
                    slope: None,
                    confidence: 0.0,
                };
            }
        }

        // DIVERGENT: no classifiable pattern.
        DeltaAnalysis {
            delta_type: DeltaType::Divergent,
            terminal_value,
            convergence_score: 0.0,
            slope: None,
            confidence: 0.0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: f64 = 0.0;
    const T1: f64 = 1.0;
    const T2: f64 = 2.0;
    const T3: f64 = 3.0;

    // --- analyze_categorical ---

    #[test]
    fn test_categorical_convergent() {
        // A, B, B → terminal=B, k=2, C=2/3≈0.667 ≥ 0.5 → CONVERGENT
        let seq = vec![
            ("A".to_string(), T0),
            ("B".to_string(), T1),
            ("B".to_string(), T2),
        ];
        let result = DeltaFeatureExtractor::analyze_categorical(&seq, 0.5);
        assert_eq!(result.delta_type, DeltaType::Convergent);
        assert!((result.convergence_score - 2.0 / 3.0).abs() < 0.001);
    }

    #[test]
    fn test_categorical_static() {
        // All same → STATIC, score=1.0
        let seq = vec![
            ("X".to_string(), T0),
            ("X".to_string(), T1),
            ("X".to_string(), T2),
        ];
        let result = DeltaFeatureExtractor::analyze_categorical(&seq, 0.5);
        assert_eq!(result.delta_type, DeltaType::Static);
        assert_eq!(result.convergence_score, 1.0);
    }

    #[test]
    fn test_categorical_oscillating() {
        // A, B, A, B → period-2 on last 4 → OSCILLATING
        let seq = vec![
            ("A".to_string(), T0),
            ("B".to_string(), T1),
            ("A".to_string(), T2),
            ("B".to_string(), T3),
        ];
        let result = DeltaFeatureExtractor::analyze_categorical(&seq, 0.5);
        assert_eq!(result.delta_type, DeltaType::Oscillating);
    }

    // --- analyze_numerical ---

    #[test]
    fn test_numerical_monotone() {
        // 1.0, 2.0, 3.0 → diffs=[1.0, 1.0], all positive → MONOTONE, slope=1.0
        let seq = vec![(1.0, T0), (2.0, T1), (3.0, T2)];
        let result = DeltaFeatureExtractor::analyze_numerical(&seq, 0.8);
        assert_eq!(result.delta_type, DeltaType::Monotone);
        let slope = result.slope.expect("slope must be Some for MONOTONE");
        assert!((slope - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_length_one_categorical_is_static() {
        let seq = vec![("A".to_string(), T0)];
        let result = DeltaFeatureExtractor::analyze_categorical(&seq, 0.5);
        assert_eq!(result.delta_type, DeltaType::Static);
        assert_eq!(result.convergence_score, 1.0);
    }

    #[test]
    fn test_length_one_numerical_is_static() {
        let seq = vec![(42.0, T0)];
        let result = DeltaFeatureExtractor::analyze_numerical(&seq, 0.8);
        assert_eq!(result.delta_type, DeltaType::Static);
        assert_eq!(result.convergence_score, 1.0);
        assert!(result.slope.is_none());
    }

    // --- DeltaType string repr ---

    #[test]
    fn test_delta_type_string_repr() {
        assert_eq!(DeltaType::Static.as_str(), "STATIC");
        assert_eq!(DeltaType::Convergent.as_str(), "CONVERGENT");
        assert_eq!(DeltaType::Monotone.as_str(), "MONOTONE");
        assert_eq!(DeltaType::Oscillating.as_str(), "OSCILLATING");
        assert_eq!(DeltaType::Divergent.as_str(), "DIVERGENT");
    }

    #[test]
    fn test_delta_type_display() {
        assert_eq!(format!("{}", DeltaType::Static), "STATIC");
        assert_eq!(format!("{}", DeltaType::Convergent), "CONVERGENT");
        assert_eq!(format!("{}", DeltaType::Monotone), "MONOTONE");
        assert_eq!(format!("{}", DeltaType::Oscillating), "OSCILLATING");
        assert_eq!(format!("{}", DeltaType::Divergent), "DIVERGENT");
    }
}
