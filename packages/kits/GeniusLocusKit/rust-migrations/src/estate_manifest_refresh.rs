// estate_manifest_refresh.rs — keeps an estate's manifest (`estate.json`)
// truthful after an open. Every process that opens an estate and runs the
// migration chain (mootx01 serve, drain, dream and upgrade; aria-mcp) calls
// this afterwards: a migration changes what is on disk, and the manifest
// must say so. Older estates that predate the manifest get one here too.
//
// Twin of Swift `EstateManifestRefresh` (GeniusLocusKitMigrations). The
// manifest is written through the catalog, the one place that spells estate
// files. `created` is preserved from an existing manifest and set to `now`
// only when there was none. Lives in the migrations crate because the chain
// whose result it records is defined here: a chain that returns `Ok` leaves
// the estate at `EstateFormatVersion::CURRENT`.

use genius_locus_kit::estate_catalog::{
    EstateCatalog, EstateCatalogError, EstateManifest, EstateManifestEncryption, EstateRecord,
};
use genius_locus_kit::estate_format::EstateFormatVersion;

/// Rewrite `estate.json` after the migration chain ran. Returns whether the
/// file changed. `now_millis` is the wall clock at the command boundary.
pub fn refresh_after_chain(
    estate: &EstateRecord,
    encryption: EstateManifestEncryption,
    now_millis: i64,
) -> Result<bool, EstateCatalogError> {
    refresh(estate, EstateFormatVersion::CURRENT, encryption, now_millis)
}

/// Write the manifest the estate should carry: its name, the composite schema
/// version, `format`, `encryption`, and the existing `created` (or `now`).
/// Returns false when the manifest already said exactly this.
pub fn refresh(
    estate: &EstateRecord,
    format: EstateFormatVersion,
    encryption: EstateManifestEncryption,
    now_millis: i64,
) -> Result<bool, EstateCatalogError> {
    let existing = EstateCatalog::read_manifest(estate).ok();
    let created = existing
        .as_ref()
        .map(|m| m.created.clone())
        .unwrap_or_else(|| iso8601_utc(now_millis));
    let current = EstateManifest::new(
        estate.name.clone(),
        composite_schema_version(),
        format,
        encryption,
        created,
    );
    if existing.as_ref() == Some(&current) {
        return Ok(false);
    }
    EstateCatalog::write_manifest(&current, estate)?;
    Ok(true)
}

/// Whether the estate's manifest declares plaintext.
pub fn declares_plaintext(estate: &EstateRecord) -> bool {
    EstateCatalog::read_manifest(estate)
        .map(|m| m.encryption == EstateManifestEncryption::Plaintext)
        .unwrap_or(false)
}

/// The composite GLK schema version (the live sum of the component
/// declarations), as the manifest records it.
pub fn composite_schema_version() -> u32 {
    u32::try_from(genius_locus_kit::hydration::composite_schema().version)
        .expect("the composite schema version is non-negative")
}

/// `YYYY-MM-DDTHH:MM:SSZ` for an epoch-millisecond instant. Written by hand
/// so the migrations crate takes no date dependency; the civil-date step is
/// the standard days-to-date algorithm.
pub fn iso8601_utc(epoch_millis: i64) -> String {
    let secs = epoch_millis.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    // Days since 1970-01-01 to civil date (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso8601_matches_known_instants() {
        assert_eq!(iso8601_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601_utc(1_788_825_600_000), "2026-09-08T00:00:00Z");
        assert_eq!(iso8601_utc(951_782_400_000), "2000-02-29T00:00:00Z");
        assert_eq!(iso8601_utc(1_735_603_200_000 + 86_399_000), "2024-12-31T23:59:59Z");
    }
}
