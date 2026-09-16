//! Offline estate-format 1.9 -> 1.10. Only calibration survives the legacy BLOB.
use genius_locus_kit::{
    estate_format::{EstateFormatStore, EstateFormatVersion},
    matrix::{
        MatrixCalibrationBucket, MatrixCalibrationCurve, MatrixCalibrationRegistry,
        MatrixRecordStore, MatrixRefreshLimits, MatrixRefreshWorker,
    },
};
use persistence_kit::*;
use std::sync::{atomic::AtomicBool, Arc};

fn failure(reason: impl ToString) -> StorageError {
    StorageError::BackendError {
        underlying: format!("matrix migration: {}", reason.to_string()),
    }
}
pub fn legacy_matrix_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "GeniusLocusKitMatrix",
        1,
        vec![TableDeclaration::new(
            "matrix_snapshot",
            vec![
                ColumnDeclaration::text("estate_id"),
                ColumnDeclaration::int("schema_version"),
                ColumnDeclaration::blob("snapshot"),
                ColumnDeclaration::text("last_hlc"),
                ColumnDeclaration::timestamp("updated_at"),
                ColumnDeclaration::json("ext").nullable(),
            ],
            vec!["estate_id".into()],
        )],
    )
}

/// Caller owns exclusive access. Interrupted rebuilds restart from authoritative
/// audit rows; completed rebuilds resume at physical reclamation.
/// Run the 1.9 → 1.10 matrix-records upgrade. Returns `true` when a legacy
/// snapshot blob was found and retired (actual data migration occurred);
/// returns `false` for a no-op pass that only stamps the new format. The
/// caller may discard the bool when it does not track migration state.
pub fn migrate_matrix_records(
    storage: Arc<dyn Storage>,
    id: &str,
    now_millis: i64,
    limits: MatrixRefreshLimits,
) -> StorageResult<bool> {
    let format = EstateFormatStore::new(storage.clone());
    let found = format
        .read_if_present()
        .map_err(|e| failure(format!("{e:?}")))?;
    if found.is_some_and(|f| f > EstateFormatVersion::V1_10) {
        return Err(failure("newer estate format"));
    }
    if found == Some(EstateFormatVersion::V1_10) {
        return Ok(false);
    }
    let mut did_migrate = false;
    let store = MatrixRecordStore::new(storage.clone());
    store.prepare()?;
    let mut phase = store
        .state(id)?
        .and_then(|r| match r.get("migration_phase") {
            Some(TypedValue::Text(p)) => Some(p.clone()),
            _ => None,
        });
    if (phase.as_deref() != Some("reclaimPending") && phase.as_deref() != Some("complete"))
        || store.active_generation(id)?.is_none()
    {
        if storage.current_schema_version_for("GeniusLocusKitMatrix")? < 2 {
            storage.migrate(&legacy_matrix_schema())?;
            let rows = storage
                .row_store()
                .query("matrix_snapshot", None, &[], Some(2), None)?;
            if rows.len() > 1 {
                return Err(failure("legacy table has multiple estates"));
            }
            if let Some(row) = rows.first() {
                if !matches!(row.get("estate_id"),Some(TypedValue::Text(owner)) if owner.eq_ignore_ascii_case(id))
                {
                    return Err(failure("legacy estate ownership mismatch"));
                }
                let bytes = match row.get("snapshot") {
                    Some(TypedValue::Blob(b)) => b,
                    _ => return Err(failure("invalid legacy payload")),
                };
                let calibration = decode_legacy_calibration(bytes)?;
                for model in calibration.curves.keys() {
                    store.save_calibration(id, &calibration, model)?;
                }
                if store.load_calibration(id)? != calibration {
                    return Err(failure("calibration verification failed; legacy retained"));
                }
                // A legacy blob was found and its calibration extracted; this
                // pass migrated real data.
                did_migrate = true;
            }
            store.set_migration(id, "rebuilding", 0)?;
            let mut retired = SchemaDeclaration::new("GeniusLocusKitMatrix", 2, vec![]);
            retired.migrations.push(Migration {
                from_version: 1,
                to_version: 2,
                operations: vec![SchemaOperation::DropTable {
                    name: "matrix_snapshot".into(),
                }],
            });
            storage.migrate(&retired)?;
        }
        store.invalidate(id)?;
        let worker = MatrixRefreshWorker::new(storage.clone(), id.into(), None, false);
        let result = worker
            .request(now_millis, limits, false)
            .and_then(|(_, ticket)| {
                ticket
                    .wait()
                    .map_err(failure)
                    .and_then(|v| v.ok_or_else(|| failure("rebuild produced no result")))
            });
        worker.close();
        let rebuilt = result?;
        if store.load(id, limits.cells)?.as_ref() != Some(rebuilt.as_ref()) {
            return Err(failure("rebuilt matrix verification failed"));
        }
        let active = store.active_generation(id)?.into_iter().collect();
        store.prune(id, &active, &AtomicBool::new(false))?;
        store.set_migration(id, "reclaimPending", 0)?;
        phase = Some("reclaimPending".into());
    }
    if phase.as_deref() != Some("complete") {
        let report = storage.perform_maintenance(None, None).map_err(failure)?;
        if report.backend == "unsupported" || (report.backend == "sqlite" && !report.performed) {
            return Err(failure("physical reclamation unavailable"));
        }
        store.set_migration(id, "complete", report.reclaimed_bytes)?;
    }
    format
        .stamp(EstateFormatVersion::V1_10, now_millis)
        .map_err(|e| failure(format!("{e:?}")))?;
    Ok(did_migrate)
}

/// Skip disposable count sections without constructing another matrix. This
/// decoder is confined to the floor-selected migration crate; no legacy writer.
pub fn decode_legacy_calibration(bytes: &[u8]) -> StorageResult<MatrixCalibrationRegistry> {
    struct Reader<'a> {
        bytes: &'a [u8],
        pos: usize,
    }
    impl<'a> Reader<'a> {
        fn take(&mut self, n: usize) -> StorageResult<&'a [u8]> {
            let end = self
                .pos
                .checked_add(n)
                .filter(|n| *n <= self.bytes.len())
                .ok_or_else(|| failure("truncated legacy payload"))?;
            let out = &self.bytes[self.pos..end];
            self.pos = end;
            Ok(out)
        }
        fn u32(&mut self) -> StorageResult<u32> {
            Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
        }
        fn string(&mut self) -> StorageResult<String> {
            let n = self.u32()? as usize;
            String::from_utf8(self.take(n)?.to_vec()).map_err(failure)
        }
        fn coord(&mut self) -> StorageResult<()> {
            let n = self.u32()? as usize;
            self.take(n)?;
            match self.take(1)?[0] {
                0 => {}
                1 | 2 => {
                    self.take(8)?;
                }
                3 | 4 => {
                    let n = self.u32()? as usize;
                    self.take(n)?;
                }
                _ => return Err(failure("invalid legacy value tag")),
            }
            Ok(())
        }
    }
    let mut r = Reader { bytes, pos: 0 };
    let version = r.u32()?;
    if version != 1 && version != 2 {
        return Err(failure("unsupported legacy schema"));
    }
    r.take(40)?; // snapshot HLC, live count, tier HLC
    for _ in 0..r.u32()? {
        let n = r.u32()? as usize;
        r.take(n)?;
        r.take(9)?;
    }
    for _ in 0..r.u32()? {
        r.coord()?;
        r.coord()?;
        r.take(8)?;
    }
    for _ in 0..r.u32()? {
        r.coord()?;
        r.coord()?;
        r.take(12)?;
    }
    let mut registry = MatrixCalibrationRegistry::default();
    for _ in 0..r.u32()? {
        let model = r.string()?;
        if r.u32()? != 20 || registry.curves.contains_key(&model) {
            return Err(failure("invalid calibration curve"));
        }
        let mut buckets = Vec::with_capacity(20);
        for _ in 0..20 {
            let count = r.u32()? as i32;
            let rate = f32::from_bits(r.u32()?);
            if count < 0 || !rate.is_finite() || !(0.0..=1.0).contains(&rate) {
                return Err(failure("invalid calibration bucket"));
            }
            buckets.push(MatrixCalibrationBucket {
                count,
                success_rate: rate,
            });
        }
        registry
            .curves
            .insert(model, MatrixCalibrationCurve { buckets });
    }
    r.take(16)?; // temporal cursor
    if version == 2 {
        for _ in 0..r.u32()? {
            let model = r.string()?;
            let time = f64::from_le_bytes(r.take(8)?.try_into().unwrap());
            if !time.is_finite()
                || !registry.curves.contains_key(&model)
                || registry.update_timestamps.insert(model, time).is_some()
            {
                return Err(failure("invalid calibration timestamp"));
            }
        }
    }
    if r.pos != bytes.len() {
        return Err(failure("trailing legacy payload"));
    }
    Ok(registry)
}
