// hydration_representation.rs — the recall-hydration representation
// selector (SPEC_DISTILLATION_STORAGE §10.1/§10.2). Rust twin of
// HydrationRepresentation.swift.
//
// The selector affects ONLY what text hydrates into results; it never
// affects which results match or how they rank (§9 search isolation).
// Tokenized variants are computed at retrieval time and never stored.

use locus_kit::drawer::Drawer;

/// Which representation of a drawer's text hydrates into a recall result
/// (SPEC §10.1). Wire spellings match the Swift raw values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HydrationRepresentation {
    /// The verbatim `content` column (default — today's behavior).
    Content,
    /// The `distilled` column (§10.2 fallback to content when NULL).
    Distilled,
    /// `content` passed through the §7.6 token-compaction transform at read.
    ContentTokenized,
    /// `distilled` passed through the §7.6 transform at read (§10.2
    /// fallback to the tokenized content when NULL).
    DistilledTokenized,
}

impl HydrationRepresentation {
    /// Parse the wire spelling. Mirrors the Swift raw values.
    pub fn from_wire(name: &str) -> Option<Self> {
        match name {
            "content" => Some(Self::Content),
            "distilled" => Some(Self::Distilled),
            "content_tokenized" => Some(Self::ContentTokenized),
            "distilled_tokenized" => Some(Self::DistilledTokenized),
            _ => None,
        }
    }
}

/// The resolved hydration text for one result row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HydratedRepresentation {
    /// The text to surface for this row under the requested selector.
    pub text: String,
    /// True when a DISTILLED variant was requested but the row carries no
    /// representation yet (pre-sweep, or the §7.3 edit-to-regeneration
    /// window), so the corresponding CONTENT variant was served instead.
    /// A per-result response field, never stored state (§10.2). Always
    /// false for the content variants.
    pub served_from_content: bool,
}

/// Resolve the hydrated text for `drawer` under `selector`. Pure —
/// tokenized variants run the §7.6 transform at read; nothing is stored.
/// Mirrors Swift `HydrationRepresentation.resolve(for:)`.
pub fn resolve_hydration_representation(
    selector: HydrationRepresentation,
    drawer: &Drawer,
) -> HydratedRepresentation {
    use substrate_ml::token_compaction::compact;
    match selector {
        HydrationRepresentation::Content => HydratedRepresentation {
            text: drawer.content.clone(),
            served_from_content: false,
        },
        HydrationRepresentation::ContentTokenized => HydratedRepresentation {
            text: compact(&drawer.content),
            served_from_content: false,
        },
        HydrationRepresentation::Distilled => match &drawer.distilled {
            Some(distilled) => HydratedRepresentation {
                text: distilled.clone(),
                served_from_content: false,
            },
            None => HydratedRepresentation {
                text: drawer.content.clone(),
                served_from_content: true,
            },
        },
        HydrationRepresentation::DistilledTokenized => match &drawer.distilled {
            Some(distilled) => HydratedRepresentation {
                text: compact(distilled),
                served_from_content: false,
            },
            None => HydratedRepresentation {
                text: compact(&drawer.content),
                served_from_content: true,
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drawer(content: &str, distilled: Option<&str>) -> Drawer {
        let mut d = Drawer::new("d1", content, "parent", "tester", 0, "m1");
        d.distilled = distilled.map(|s| s.to_string());
        if distilled.is_some() {
            d.distilled_pipeline_version = Some("p1".to_string());
            d.distilled_token_count = Some(1);
            d.distilled_at = Some(0);
        }
        d
    }

    #[test]
    fn content_variants_never_mark_fallback() {
        let d = drawer("The original body.", None);
        let c = resolve_hydration_representation(HydrationRepresentation::Content, &d);
        assert_eq!(c.text, "The original body.");
        assert!(!c.served_from_content);
        let ct = resolve_hydration_representation(HydrationRepresentation::ContentTokenized, &d);
        assert_eq!(ct.text, "Original body.");
        assert!(!ct.served_from_content);
    }

    #[test]
    fn distilled_serves_representation_when_present() {
        let d = drawer("The original body.", Some("Original body dense."));
        let r = resolve_hydration_representation(HydrationRepresentation::Distilled, &d);
        assert_eq!(r.text, "Original body dense.");
        assert!(!r.served_from_content);
    }

    #[test]
    fn distilled_falls_back_to_content_with_marker() {
        let d = drawer("The original body.", None);
        let r = resolve_hydration_representation(HydrationRepresentation::Distilled, &d);
        assert_eq!(r.text, "The original body.");
        assert!(r.served_from_content, "§10.2 fallback must be marked");
        let rt =
            resolve_hydration_representation(HydrationRepresentation::DistilledTokenized, &d);
        assert_eq!(rt.text, "Original body.");
        assert!(rt.served_from_content);
    }

    #[test]
    fn wire_spellings_round_trip() {
        for (name, sel) in [
            ("content", HydrationRepresentation::Content),
            ("distilled", HydrationRepresentation::Distilled),
            ("content_tokenized", HydrationRepresentation::ContentTokenized),
            ("distilled_tokenized", HydrationRepresentation::DistilledTokenized),
        ] {
            assert_eq!(HydrationRepresentation::from_wire(name), Some(sel));
        }
        assert_eq!(HydrationRepresentation::from_wire("bogus"), None);
    }
}
