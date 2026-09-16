//! Native keyed matrix persistence. No complete matrix is serialized or bound.
use super::*;
use crate::audit::UnifiedAuditValue;
use base64::{engine::general_purpose::STANDARD, Engine};
use persistence_kit::*;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

pub const BATCH_SIZE: usize = 256;
pub const DEFAULT_CELL_LIMIT: usize = 1_000_000;
type Values = BTreeMap<String, TypedValue>;
pub(crate) fn fail(reason: impl Into<String>) -> StorageError {
    StorageError::BackendError {
        underlying: format!("matrix: {}", reason.into()),
    }
}
pub(crate) fn check_cancel(cancel: &AtomicBool) -> StorageResult<()> {
    if cancel.load(Ordering::Acquire) {
        Err(fail("cancelled"))
    } else {
        Ok(())
    }
}
fn values<const N: usize>(pairs: [(&str, TypedValue); N]) -> Values {
    pairs.into_iter().map(|(k, v)| (k.to_owned(), v)).collect()
}
fn text(s: impl Into<String>) -> TypedValue {
    TypedValue::Text(s.into())
}
pub fn string(v: &Values, key: &str) -> StorageResult<String> {
    match v.get(key) {
        Some(TypedValue::Text(s)) => Ok(s.clone()),
        _ => Err(fail(format!("invalid {key}"))),
    }
}
fn integer(v: &Values, key: &str) -> StorageResult<i64> {
    match v.get(key) {
        Some(TypedValue::Int(n)) => Ok(*n),
        _ => Err(fail(format!("invalid {key}"))),
    }
}
fn watermark(v: &Values, prefix: &str) -> StorageResult<substrate_types::hlc::HLC> {
    Ok(substrate_types::hlc::HLC::new(
        integer(v, &format!("{prefix}_physical_ms"))?,
        i32::try_from(integer(v, &format!("{prefix}_logical"))?)
            .map_err(|_| fail("invalid logical cursor"))?,
        i32::try_from(integer(v, &format!("{prefix}_node"))?)
            .map_err(|_| fail("invalid node cursor"))?,
    ))
}
fn estate(table: &str, id: &str) -> StoragePredicate {
    StoragePredicate::Eq(Column::new(table, "estate_id"), text(id.to_lowercase()))
}
fn generation(table: &str, id: &str, gen: &str) -> StoragePredicate {
    StoragePredicate::And(vec![
        estate(table, id),
        StoragePredicate::Eq(Column::new(table, "generation"), text(gen)),
    ])
}
fn upsert(rows: &dyn RowStore, table: &str, v: Values, key: &[&str]) -> StorageResult<()> {
    rows.upsert(
        table,
        v,
        &key.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
    )
    .map(|_| ())
}

#[derive(Clone)]
pub struct MatrixRecordStore {
    pub(crate) storage: Arc<dyn Storage>,
}
impl MatrixRecordStore {
    pub fn new(storage: Arc<dyn Storage>) -> Self {
        Self { storage }
    }
    pub fn schema_declaration() -> SchemaDeclaration {
        use ColumnDeclaration as C;
        fn table(name: &str, cols: Vec<ColumnDeclaration>, key: &[&str]) -> TableDeclaration {
            TableDeclaration::new(name, cols, key.iter().map(|s| s.to_string()).collect())
        }
        SchemaDeclaration::new(
            "GeniusLocusKitMatrixRecords",
            2,
            vec![
                table(
                    "matrix_state",
                    vec![
                        C::text("estate_id"),
                        C::text("active_generation").nullable(),
                        C::text("migration_phase"),
                        C::int("reclaimed_bytes"),
                        C::text("reason").nullable(),
                        C::json("ext").nullable(),
                    ],
                    &["estate_id"],
                ),
                table(
                    "matrix_generations",
                    vec![
                        C::text("estate_id"),
                        C::text("generation"),
                        C::text("phase"),
                        C::int("cell_count"),
                        C::int("live_row_count"),
                        C::int("last_physical_ms"),
                        C::int("last_logical"),
                        C::int("last_node"),
                        C::int("temporal_physical_ms"),
                        C::int("temporal_logical"),
                        C::int("temporal_node"),
                        C::int("decayed_as_of_ms"),
                        C::timestamp("updated_at"),
                        C::json("ext").nullable(),
                    ],
                    &["estate_id", "generation"],
                ),
                table(
                    "matrix_cells",
                    vec![
                        C::text("estate_id"),
                        C::text("generation"),
                        C::text("cell_id"),
                        C::text("family"),
                        C::text("a_field"),
                        C::text("a_kind"),
                        C::text("a_value"),
                        C::text("b_field"),
                        C::text("b_kind"),
                        C::text("b_value"),
                        C::int("lag"),
                        C::int("count").nullable(),
                        C::float("decayed").nullable(),
                        C::json("ext").nullable(),
                    ],
                    &["estate_id", "generation", "cell_id"],
                ),
                table(
                    "matrix_calibration",
                    vec![
                        C::text("estate_id"),
                        C::text("model_id"),
                        C::int("bucket"),
                        C::int("count"),
                        C::float("success_rate"),
                        C::float("updated_seconds").nullable(),
                        C::json("ext").nullable(),
                    ],
                    &["estate_id", "model_id", "bucket"],
                ),
            ],
        )
    }
    pub fn prepare(&self) -> StorageResult<()> {
        self.storage.migrate(&Self::schema_declaration())
    }

    pub fn status_metadata(&self, id: &str) -> StorageResult<MatrixRefreshStatus> {
        let mut status = MatrixRefreshStatus::default();
        if let Some(state) = self.state(id)? {
            status.migration_phase = string(&state.values, "migration_phase")?;
            status.reclaimed_bytes = integer(&state.values, "reclaimed_bytes")?;
            if let Some(TypedValue::Text(gen)) = state.get("active_generation") {
                status.generation = Some(gen.clone());
                if let Some(meta) = self
                    .storage
                    .row_store()
                    .query(
                        "matrix_generations",
                        Some(&generation("matrix_generations", id, gen)),
                        &[],
                        Some(1),
                        None,
                    )?
                    .first()
                {
                    status.watermark = watermark(&meta.values, "last")?;
                }
            }
        }
        Ok(status)
    }
    pub fn state(&self, id: &str) -> StorageResult<Option<StorageRow>> {
        if self
            .storage
            .current_schema_version_for("GeniusLocusKitMatrixRecords")?
            == 0
        {
            return Ok(None);
        }
        Ok(self
            .storage
            .row_store()
            .query(
                "matrix_state",
                Some(&estate("matrix_state", id)),
                &[],
                Some(1),
                None,
            )?
            .into_iter()
            .next())
    }
    fn empty_state(id: &str) -> Values {
        values([
            ("estate_id", text(id.to_lowercase())),
            ("active_generation", TypedValue::Null),
            ("migration_phase", text("complete")),
            ("reclaimed_bytes", TypedValue::Int(0)),
            ("reason", TypedValue::Null),
        ])
    }
    pub fn active_generation(&self, id: &str) -> StorageResult<Option<String>> {
        Ok(self
            .state(id)?
            .and_then(|r| match r.get("active_generation") {
                Some(TypedValue::Text(s)) => Some(s.clone()),
                _ => None,
            }))
    }
    pub fn set_migration(&self, id: &str, phase: &str, reclaimed: i64) -> StorageResult<()> {
        let mut v = self
            .state(id)?
            .map(|r| r.values)
            .unwrap_or_else(|| Self::empty_state(id));
        v.insert("migration_phase".into(), text(phase));
        v.insert("reclaimed_bytes".into(), TypedValue::Int(reclaimed));
        upsert(
            self.storage.row_store().as_ref(),
            "matrix_state",
            v,
            &["estate_id"],
        )
    }
    pub fn invalidate(&self, id: &str) -> StorageResult<()> {
        self.storage
            .row_store()
            .update(
                "matrix_state",
                values([("active_generation", TypedValue::Null)]),
                &estate("matrix_state", id),
            )
            .map(|_| ())
    }
    pub fn stage(
        &self,
        id: &str,
        tier: &MatrixTier,
        gen: &str,
        now_millis: i64,
        limit: usize,
        cancel: &AtomicBool,
    ) -> StorageResult<()> {
        let size = tier.field_presence.len()
            + tier.co_occurrence.len()
            + tier.temporal_causality.len()
            + tier.co_occurrence_decayed.len()
            + tier.temporal_causality_decayed.len();
        if size > limit {
            return Err(fail("deferred: matrix cell budget exceeded"));
        }
        check_cancel(cancel)?;
        let mut cells = cell_rows(tier);
        let cell_count = tier.field_presence.len()
            + tier.co_occurrence.len()
            + tier.temporal_causality.len()
            + tier
                .co_occurrence_decayed
                .keys()
                .filter(|k| !tier.co_occurrence.contains_key(k))
                .count()
            + tier
                .temporal_causality_decayed
                .keys()
                .filter(|k| !tier.temporal_causality.contains_key(k))
                .count();
        upsert(
            self.storage.row_store().as_ref(),
            "matrix_generations",
            values([
                ("estate_id", text(id.to_lowercase())),
                ("generation", text(gen)),
                ("phase", text("staging")),
                ("cell_count", TypedValue::Int(cell_count as i64)),
                ("live_row_count", TypedValue::Int(tier.live_row_count)),
                (
                    "last_physical_ms",
                    TypedValue::Int(tier.last_hlc.physical_time),
                ),
                (
                    "last_logical",
                    TypedValue::Int(tier.last_hlc.logical_count as i64),
                ),
                ("last_node", TypedValue::Int(tier.last_hlc.node_id as i64)),
                (
                    "temporal_physical_ms",
                    TypedValue::Int(tier.temporal_watermark_hlc.physical_time),
                ),
                (
                    "temporal_logical",
                    TypedValue::Int(tier.temporal_watermark_hlc.logical_count as i64),
                ),
                (
                    "temporal_node",
                    TypedValue::Int(tier.temporal_watermark_hlc.node_id as i64),
                ),
                ("decayed_as_of_ms", TypedValue::Int(tier.decayed_as_of_ms)),
                ("updated_at", TypedValue::Timestamp(now_millis)),
            ]),
            &["estate_id", "generation"],
        )?;
        loop {
            let batch: Vec<_> = cells.by_ref().take(BATCH_SIZE).collect();
            if batch.is_empty() {
                break;
            }
            check_cancel(cancel)?;
            self.storage
                .transaction(IsolationLevel::Serializable, &mut |tx| {
                    for cell in &batch {
                        let mut v = cell.clone();
                        v.insert("estate_id".into(), text(id.to_lowercase()));
                        v.insert("generation".into(), text(gen));
                        upsert(
                            tx.row_store().as_ref(),
                            "matrix_cells",
                            v,
                            &["estate_id", "generation", "cell_id"],
                        )?;
                    }
                    Ok(())
                })?;
            std::thread::yield_now();
        }
        if self
            .storage
            .row_store()
            .count("matrix_cells", Some(&generation("matrix_cells", id, gen)))?
            != cell_count
        {
            return Err(fail("staging count mismatch"));
        }
        self.storage.row_store().update(
            "matrix_generations",
            values([("phase", text("ready"))]),
            &generation("matrix_generations", id, gen),
        )?;
        Ok(())
    }
    pub fn publish(
        &self,
        id: &str,
        gen: &str,
        expected: Option<&str>,
        audit_count: Option<usize>,
        cancel: &AtomicBool,
    ) -> StorageResult<()> {
        self.storage
            .transaction(IsolationLevel::Serializable, &mut |tx| {
                check_cancel(cancel)?;
                if let Some(n) = audit_count {
                    if tx.audit_log().count()? != n {
                        return Err(fail("deferred: source changed"));
                    }
                }
                let state = tx
                    .row_store()
                    .query(
                        "matrix_state",
                        Some(&estate("matrix_state", id)),
                        &[],
                        Some(1),
                        None,
                    )?
                    .into_iter()
                    .next();
                let mut v = state
                    .map(|r| r.values)
                    .unwrap_or_else(|| Self::empty_state(id));
                let current = match v.get("active_generation") {
                    Some(TypedValue::Text(s)) => Some(s.as_str()),
                    _ => None,
                };
                if current != expected {
                    return Err(fail("deferred: publication conflict"));
                }
                let meta = tx.row_store().query(
                    "matrix_generations",
                    Some(&generation("matrix_generations", id, gen)),
                    &[],
                    Some(1),
                    None,
                )?;
                if meta.first().map(|r| r.get("phase")) != Some(Some(&text("ready"))) {
                    return Err(fail("incomplete generation"));
                }
                v.insert("active_generation".into(), text(gen));
                check_cancel(cancel)?;
                upsert(tx.row_store().as_ref(), "matrix_state", v, &["estate_id"])
            })
    }
    pub fn load(&self, id: &str, limit: usize) -> StorageResult<Option<MatrixTier>> {
        self.active_generation(id)?
            .map(|gen| self.load_generation(id, &gen, limit))
            .transpose()
    }
    pub fn load_generation(&self, id: &str, gen: &str, limit: usize) -> StorageResult<MatrixTier> {
        let meta = self
            .storage
            .row_store()
            .query(
                "matrix_generations",
                Some(&generation("matrix_generations", id, gen)),
                &[],
                Some(1),
                None,
            )?
            .into_iter()
            .next()
            .ok_or_else(|| fail("missing generation"))?;
        if string(&meta.values, "phase")? != "ready" {
            return Err(fail("incomplete generation"));
        }
        let count = integer(&meta.values, "cell_count")?;
        if count < 0 || count as usize > limit {
            return Err(fail("deferred: stored matrix cell budget exceeded"));
        }
        let mut tier = MatrixTier::new();
        tier.live_row_count = integer(&meta.values, "live_row_count")?;
        tier.last_hlc = watermark(&meta.values, "last")?;
        tier.temporal_watermark_hlc = watermark(&meta.values, "temporal")?;
        tier.decayed_as_of_ms = integer(&meta.values, "decayed_as_of_ms")?;
        let mut offset = 0;
        let mut last_cell_id: Option<String> = None;
        while offset < count as usize {
            let mut predicate = generation("matrix_cells", id, gen);
            if let Some(cursor) = &last_cell_id {
                predicate = StoragePredicate::And(vec![
                    predicate,
                    StoragePredicate::Gt(Column::new("matrix_cells", "cell_id"), text(cursor)),
                ]);
            }
            let rows = self.storage.row_store().query(
                "matrix_cells",
                Some(&predicate),
                &[OrderClause::ascending(Column::new(
                    "matrix_cells",
                    "cell_id",
                ))],
                Some(BATCH_SIZE),
                None,
            )?;
            if rows.is_empty() {
                return Err(fail("truncated matrix generation"));
            }
            offset += rows.len();
            last_cell_id = Some(string(&rows.last().unwrap().values, "cell_id")?);
            for row in rows {
                let v = &row.values;
                let count = match row.get("count") {
                    Some(TypedValue::Int(n)) => Some(*n),
                    Some(TypedValue::Null) => None,
                    _ => return Err(fail("invalid count")),
                };
                let decay = match row.get("decayed") {
                    Some(TypedValue::Float(d)) if d.is_finite() => Some(*d),
                    Some(TypedValue::Null) | None => None,
                    _ => return Err(fail("invalid decay")),
                };
                match string(v, "family")?.as_str() {
                    "f" => {
                        let bit = string(v, "a_value")?
                            .parse::<u8>()
                            .map_err(|_| fail("invalid field bit"))?;
                        if bit >= 64 {
                            return Err(fail("invalid field bit"));
                        }
                        tier.field_presence.insert(
                            MatrixFieldCell::new(string(v, "a_field")?, bit),
                            count.ok_or_else(|| fail("missing F count"))?,
                        );
                    }
                    "o" => {
                        let key = MatrixCoOccurKey::new(coord(v, "a")?, coord(v, "b")?);
                        if let Some(n) = count {
                            tier.co_occurrence.insert(key.clone(), n);
                        }
                        if let Some(d) = decay {
                            tier.co_occurrence_decayed.insert(key, d);
                        }
                    }
                    "t" => {
                        let lag = integer(v, "lag")?;
                        if lag < 0 || lag > u32::MAX as i64 {
                            return Err(fail("invalid lag"));
                        }
                        let key = MatrixTemporalKey {
                            source: coord(v, "a")?,
                            target: coord(v, "b")?,
                            lag_bucket: lag as u32,
                        };
                        if let Some(n) = count {
                            tier.temporal_causality.insert(key.clone(), n);
                        }
                        if let Some(d) = decay {
                            tier.temporal_causality_decayed.insert(key, d);
                        }
                    }
                    _ => return Err(fail("unknown cell family")),
                }
            }
        }
        if offset != count as usize {
            return Err(fail("matrix count mismatch"));
        }
        Ok(tier)
    }
    pub fn save_calibration(
        &self,
        id: &str,
        registry: &MatrixCalibrationRegistry,
        model: &str,
    ) -> StorageResult<()> {
        let Some(curve) = registry.curves.get(model) else {
            return Ok(());
        };
        self.storage
            .transaction(IsolationLevel::Serializable, &mut |tx| {
                write_curve(
                    tx.row_store().as_ref(),
                    id,
                    model,
                    curve,
                    registry.update_timestamps.get(model).copied(),
                )
            })
    }
    pub fn load_calibration(&self, id: &str) -> StorageResult<MatrixCalibrationRegistry> {
        let mut rows = Vec::new();
        let mut offset = 0;
        loop {
            let page = self.storage.row_store().query(
                "matrix_calibration",
                Some(&estate("matrix_calibration", id)),
                &[
                    OrderClause::ascending(Column::new("matrix_calibration", "model_id")),
                    OrderClause::ascending(Column::new("matrix_calibration", "bucket")),
                ],
                Some(BATCH_SIZE),
                Some(offset),
            )?;
            let n = page.len();
            rows.extend(page);
            offset += n;
            if n < BATCH_SIZE {
                break;
            }
        }
        decode_curves(&rows)
    }
    pub fn record_calibration(
        &self,
        id: &str,
        model: &str,
        confidence: f32,
        outcome: MatrixCalibrationOutcome,
        now_seconds: f64,
    ) -> StorageResult<MatrixCalibrationCurve> {
        if !confidence.is_finite() || !now_seconds.is_finite() {
            return Err(fail("nonfinite calibration input"));
        }
        let mut answer = MatrixCalibrationCurve::new();
        self.storage
            .transaction(IsolationLevel::Serializable, &mut |tx| {
                let rows = tx.row_store().query(
                    "matrix_calibration",
                    Some(&StoragePredicate::And(vec![
                        estate("matrix_calibration", id),
                        StoragePredicate::Eq(
                            Column::new("matrix_calibration", "model_id"),
                            text(model),
                        ),
                    ])),
                    &[],
                    Some(21),
                    None,
                )?;
                let mut registry = decode_curves(&rows)?;
                if registry
                    .curves
                    .values()
                    .any(|c| c.buckets.iter().any(|b| b.count == i32::MAX))
                {
                    return Err(fail("calibration count exhausted"));
                }
                registry.record_with_decay(model, confidence, outcome, now_seconds, 30.0);
                answer = registry.curves[model].clone();
                write_curve(
                    tx.row_store().as_ref(),
                    id,
                    model,
                    &answer,
                    Some(now_seconds),
                )
            })?;
        Ok(answer)
    }
    pub fn prune(
        &self,
        id: &str,
        keep: &HashSet<String>,
        cancel: &AtomicBool,
    ) -> StorageResult<()> {
        let generations = self.storage.row_store().query(
            "matrix_generations",
            Some(&estate("matrix_generations", id)),
            &[],
            None,
            None,
        )?;
        for row in generations {
            let gen = string(&row.values, "generation")?;
            if keep.contains(&gen) {
                continue;
            }
            loop {
                check_cancel(cancel)?;
                let mut count = 0;
                self.storage
                    .transaction(IsolationLevel::Serializable, &mut |tx| {
                        let active = tx.row_store().query(
                            "matrix_state",
                            Some(&estate("matrix_state", id)),
                            &[],
                            Some(1),
                            None,
                        )?;
                        if active.first().and_then(|r| r.get("active_generation"))
                            == Some(&text(&gen))
                        {
                            return Ok(());
                        }
                        let rows = tx.row_store().query(
                            "matrix_cells",
                            Some(&generation("matrix_cells", id, &gen)),
                            &[],
                            Some(BATCH_SIZE),
                            None,
                        )?;
                        count = rows.len();
                        for row in rows {
                            tx.row_store().delete(
                                "matrix_cells",
                                &StoragePredicate::And(vec![
                                    generation("matrix_cells", id, &gen),
                                    StoragePredicate::Eq(
                                        Column::new("matrix_cells", "cell_id"),
                                        text(string(&row.values, "cell_id")?),
                                    ),
                                ]),
                            )?;
                        }
                        if count == 0 {
                            tx.row_store().delete(
                                "matrix_generations",
                                &generation("matrix_generations", id, &gen),
                            )?;
                        }
                        Ok(())
                    })?;
                if count == 0 {
                    break;
                }
                std::thread::yield_now();
            }
        }
        Ok(())
    }
}

fn write_curve(
    rows: &dyn RowStore,
    id: &str,
    model: &str,
    curve: &MatrixCalibrationCurve,
    time: Option<f64>,
) -> StorageResult<()> {
    if curve.buckets.len() != 20 || time.is_some_and(|t| !t.is_finite()) {
        return Err(fail("invalid calibration curve"));
    }
    for (i, b) in curve.buckets.iter().enumerate() {
        if b.count < 0 || !b.success_rate.is_finite() || !(0.0..=1.0).contains(&b.success_rate) {
            return Err(fail("invalid calibration bucket"));
        }
        upsert(
            rows,
            "matrix_calibration",
            values([
                ("estate_id", text(id.to_lowercase())),
                ("model_id", text(model)),
                ("bucket", TypedValue::Int(i as i64)),
                ("count", TypedValue::Int(b.count as i64)),
                ("success_rate", TypedValue::Float(b.success_rate as f64)),
                (
                    "updated_seconds",
                    time.map(TypedValue::Float).unwrap_or(TypedValue::Null),
                ),
            ]),
            &["estate_id", "model_id", "bucket"],
        )?;
    }
    Ok(())
}
fn decode_curves(rows: &[StorageRow]) -> StorageResult<MatrixCalibrationRegistry> {
    let mut registry = MatrixCalibrationRegistry::default();
    let mut seen: HashMap<String, HashSet<usize>> = HashMap::new();
    let mut timestamps: HashMap<String, TypedValue> = HashMap::new();
    for row in rows {
        let v = &row.values;
        let model = string(v, "model_id")?;
        let i = integer(v, "bucket")?;
        let n = integer(v, "count")?;
        let rate = match row.get("success_rate") {
            Some(TypedValue::Float(r)) if r.is_finite() && (0.0..=1.0).contains(r) => *r,
            _ => return Err(fail("invalid calibration rate")),
        };
        if !(0..20).contains(&i)
            || !(0..=i32::MAX as i64).contains(&n)
            || !seen.entry(model.clone()).or_default().insert(i as usize)
        {
            return Err(fail("invalid calibration bucket"));
        }
        registry
            .curves
            .entry(model.clone())
            .or_insert_with(MatrixCalibrationCurve::new)
            .buckets[i as usize] = MatrixCalibrationBucket {
            count: n as i32,
            success_rate: rate as f32,
        };
        let stored_timestamp = row
            .get("updated_seconds")
            .cloned()
            .unwrap_or(TypedValue::Null);
        if timestamps
            .get(&model)
            .is_some_and(|old| old != &stored_timestamp)
            || !matches!(&stored_timestamp, TypedValue::Null | TypedValue::Float(_))
        {
            return Err(fail("inconsistent calibration timestamp"));
        }
        timestamps.insert(model.clone(), stored_timestamp);
        if let Some(TypedValue::Float(t)) = row.get("updated_seconds") {
            if !t.is_finite()
                || registry
                    .update_timestamps
                    .get(&model)
                    .is_some_and(|old| old != t)
            {
                return Err(fail("invalid calibration timestamp"));
            }
            registry.update_timestamps.insert(model, *t);
        }
    }
    if seen.values().any(|s| s.len() != 20) {
        return Err(fail("incomplete calibration curve"));
    }
    Ok(registry)
}
fn parts(c: &MatrixValueCoord) -> [String; 3] {
    let (kind, value) = match &c.value {
        UnifiedAuditValue::Null => ("null", String::new()),
        UnifiedAuditValue::Bitmap(n) => ("bitmap", n.to_string()),
        UnifiedAuditValue::Integer(n) => ("integer", n.to_string()),
        UnifiedAuditValue::StringValue(s) => ("string", s.clone()),
        UnifiedAuditValue::Bytes(b) => ("bytes", STANDARD.encode(b)),
    };
    [c.field_path.clone(), kind.into(), value]
}
fn coord(v: &Values, prefix: &str) -> StorageResult<MatrixValueCoord> {
    let payload = string(v, &format!("{prefix}_value"))?;
    let value = match string(v, &format!("{prefix}_kind"))?.as_str() {
        "null" => UnifiedAuditValue::Null,
        "bitmap" => UnifiedAuditValue::Bitmap(payload.parse().map_err(|_| fail("invalid bitmap"))?),
        "integer" => {
            UnifiedAuditValue::Integer(payload.parse().map_err(|_| fail("invalid integer"))?)
        }
        "string" => UnifiedAuditValue::StringValue(payload),
        "bytes" => UnifiedAuditValue::Bytes(
            STANDARD
                .decode(payload)
                .map_err(|_| fail("invalid bytes"))?,
        ),
        _ => return Err(fail("invalid coordinate kind")),
    };
    Ok(MatrixValueCoord::new(
        string(v, &format!("{prefix}_field"))?,
        value,
    ))
}
fn cell_rows(tier: &MatrixTier) -> impl Iterator<Item = Values> + '_ {
    fn row(
        f: &str,
        a: [String; 3],
        b: [String; 3],
        lag: u32,
        count: Option<i64>,
        decay: Option<f64>,
    ) -> Values {
        let key = std::iter::once(f.to_string())
            .chain(a.clone())
            .chain(b.clone())
            .chain(std::iter::once(lag.to_string()))
            .map(|s| format!("{}:{s}", s.len()))
            .collect::<String>();
        values([
            ("cell_id", text(key)),
            ("family", text(f)),
            ("a_field", text(&a[0])),
            ("a_kind", text(&a[1])),
            ("a_value", text(&a[2])),
            ("b_field", text(&b[0])),
            ("b_kind", text(&b[1])),
            ("b_value", text(&b[2])),
            ("lag", TypedValue::Int(lag as i64)),
            (
                "count",
                count.map(TypedValue::Int).unwrap_or(TypedValue::Null),
            ),
            (
                "decayed",
                decay.map(TypedValue::Float).unwrap_or(TypedValue::Null),
            ),
        ])
    }
    let fields = tier.field_presence.iter().map(|(k, n)| {
        row(
            "f",
            [
                k.field_path.clone(),
                "bit".into(),
                k.bit_position.to_string(),
            ],
            [String::new(), String::new(), String::new()],
            0,
            Some(*n),
            None,
        )
    });
    let occurrences = tier
        .co_occurrence
        .keys()
        .chain(
            tier.co_occurrence_decayed
                .keys()
                .filter(|k| !tier.co_occurrence.contains_key(k)),
        )
        .map(|k| {
            let mut a = parts(&k.a);
            let mut b = parts(&k.b);
            if a > b {
                std::mem::swap(&mut a, &mut b);
            }
            row(
                "o",
                a,
                b,
                0,
                tier.co_occurrence.get(k).copied(),
                tier.co_occurrence_decayed.get(k).copied(),
            )
        });
    let temporal = tier
        .temporal_causality
        .keys()
        .chain(
            tier.temporal_causality_decayed
                .keys()
                .filter(|k| !tier.temporal_causality.contains_key(k)),
        )
        .map(|k| {
            row(
                "t",
                parts(&k.source),
                parts(&k.target),
                k.lag_bucket,
                tier.temporal_causality.get(k).copied(),
                tier.temporal_causality_decayed.get(k).copied(),
            )
        });
    fields.chain(occurrences).chain(temporal)
}
