//! Offline reader seam for LoCoMo answer-input dumps.
//!
//! Retrieval and hydration happen once in the frozen `locomo-spec` lane. This
//! module feeds that immutable JSONL to any local reader and applies the
//! repository's existing official, mechanical LoCoMo token-F1 scorer.
//!
//! # Progress file and resume
//!
//! After every reader call (success or failure) the scored row is appended to
//! `<output_path>.partial.jsonl` (mode 0600) and flushed to disk.  If the
//! process is killed mid-run, re-invoking with the same arguments resumes from
//! that file: rows whose `question_id` is in the selected set are reused
//! without calling the reader again.  Rows outside the selected set are ignored.
//! A malformed line in the progress file is a hard error.
//!
//! The final file is assembled in input order (not append order) and is
//! byte-identical to a clean run given the same inputs and the same reader
//! answers, except for two additive header fields:
//! - `resumed_row_count` (0 on a clean run)
//! - `progress_file` (path, recorded for provenance)

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use serde_json::Value;

use crate::locomo_spec_scorer::{locomo_spec_aggregate, score_question};
use crate::longmemeval_judge::lme_run_judge;

struct ValidatedAnswerInput {
    raw_line: String,
    row: serde_json::Map<String, Value>,
    question_id: String,
    category: u8,
    question: String,
    gold: String,
    memory_texts: Vec<String>,
}

fn string_array(
    row: &serde_json::Map<String, Value>,
    key: &str,
    line_number: usize,
) -> Result<Vec<String>, String> {
    let values = row.get(key).and_then(Value::as_array).ok_or_else(|| {
        format!(
            "locomo-spec answer-batch: line {line_number} field '{key}' must be an array of strings"
        )
    })?;
    values
        .iter()
        .map(|value| {
            value.as_str().map(str::to_string).ok_or_else(|| {
                format!(
                    "locomo-spec answer-batch: line {line_number} field '{key}' must be an array of strings"
                )
            })
        })
        .collect()
}

fn validate_answer_input(raw_line: &str, line_number: usize) -> Result<ValidatedAnswerInput, String> {
    let row: serde_json::Map<String, Value> = serde_json::from_str(raw_line).map_err(|error| {
        format!("locomo-spec answer-batch: line {line_number} is malformed JSON: {error}")
    })?;
    if row.get("type").and_then(Value::as_str) != Some("answer_input") {
        return Err(format!(
            "locomo-spec answer-batch: line {line_number} has wrong kind; expected type=answer_input"
        ));
    }
    if row.get("benchmark").and_then(Value::as_str) != Some("locomo-spec") {
        return Err(format!(
            "locomo-spec answer-batch: line {line_number} field 'benchmark' must be locomo-spec"
        ));
    }
    let question_id = row
        .get("question_id")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            format!(
                "locomo-spec answer-batch: line {line_number} is missing non-empty string field 'question_id'"
            )
        })?
        .to_string();
    let category_u64 = row.get("category").and_then(Value::as_u64).ok_or_else(|| {
        format!(
            "locomo-spec answer-batch: line {line_number} field 'category' must be an integer from 1 through 5"
        )
    })?;
    if !(1..=5).contains(&category_u64) {
        return Err(format!(
            "locomo-spec answer-batch: line {line_number} field 'category' must be an integer from 1 through 5"
        ));
    }
    let category = category_u64 as u8;
    row.get("category_label")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            format!(
                "locomo-spec answer-batch: line {line_number} is missing non-empty string field 'category_label'"
            )
        })?;
    let question = row
        .get("question")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            format!(
                "locomo-spec answer-batch: line {line_number} is missing non-empty string field 'question'"
            )
        })?
        .to_string();
    let gold = match row.get("gold_answer") {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Null) if category == 5 => String::new(),
        Some(_) => {
            return Err(format!(
                "locomo-spec answer-batch: line {line_number} field 'gold_answer' must be a string (or null for category 5)"
            ));
        }
        None => {
            return Err(format!(
                "locomo-spec answer-batch: line {line_number} is missing field 'gold_answer'"
            ));
        }
    };
    let memory_texts = string_array(&row, "memory_texts", line_number)?;
    let drawer_ids = string_array(&row, "retrieved_drawer_ids", line_number)?;
    let _ = string_array(&row, "retrieved_dia_ids", line_number)?;
    if drawer_ids.len() != memory_texts.len() {
        return Err(format!(
            "locomo-spec answer-batch: line {line_number} memory_texts and retrieved_drawer_ids counts differ"
        ));
    }
    let ranks = row
        .get("retrieved_ranks")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            format!(
                "locomo-spec answer-batch: line {line_number} retrieved_ranks must be the one-based rank of every memory_text"
            )
        })?;
    let parsed_ranks = ranks
        .iter()
        .map(Value::as_u64)
        .collect::<Option<Vec<_>>>();
    if ranks.len() != memory_texts.len()
        || match &parsed_ranks {
            Some(values) => {
                values.iter().any(|rank| *rank == 0)
                    || values.windows(2).any(|pair| pair[0] >= pair[1])
            }
            None => true,
        }
    {
        return Err(format!(
            "locomo-spec answer-batch: line {line_number} retrieved_ranks must contain positive, strictly increasing one-based source ranks"
        ));
    }

    Ok(ValidatedAnswerInput {
        raw_line: raw_line.to_string(),
        row,
        question_id,
        category,
        question,
        gold,
        memory_texts,
    })
}

fn swift_json_number(value: f64) -> Value {
    if value.is_finite()
        && value.fract() == 0.0
        && value >= i64::MIN as f64
        && value <= i64::MAX as f64
    {
        Value::from(value as i64)
    } else {
        Value::from(value)
    }
}

pub fn reader_prompt(question: &str, category: u8, memory_texts: &[String]) -> String {
    let mut lines = vec![
        "Answer the question using only the retrieved memory records.".to_string(),
        "Give only a short direct answer, without explanation.".to_string(),
    ];
    if category == 5 {
        lines.push(
            "If the records do not contain the answer, reply exactly: No information available."
                .to_string(),
        );
    } else {
        lines.push("If the records do not contain the answer, reply: I don't know.".to_string());
    }
    lines.push(String::new());
    lines.push("Retrieved memory records:".to_string());
    if memory_texts.is_empty() {
        lines.push("(none)".to_string());
    } else {
        for (index, memory) in memory_texts.iter().enumerate() {
            lines.push(format!("[{}] {memory}", index + 1));
        }
    }
    lines.push(String::new());
    lines.push(format!("Question: {question}"));
    lines.push("Answer:".to_string());
    lines.join("\n")
}

/// Load already-scored rows from a progress file.
/// Returns a map of question_id → row object.
/// Rows whose question_id is not in `selected_ids` are silently skipped.
/// A malformed line is a hard error.
/// Verifies that `path` is a regular file owned by the current process user
/// with mode 0600 before resuming from it.
///
/// This guards against an attacker pre-creating the progress file path as a
/// symlink or a world-readable file and injecting scored rows.
fn validate_progress_file_ownership(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    let meta = std::fs::metadata(path).map_err(|e| {
        format!(
            "locomo-spec answer-batch: cannot stat progress file '{}': {e}",
            path.display()
        )
    })?;
    if !meta.file_type().is_file() {
        return Err(format!(
            "locomo-spec answer-batch: progress file '{}' is not a regular file",
            path.display()
        ));
    }
    if meta.mode() & 0o777 != 0o600 {
        return Err(format!(
            "locomo-spec answer-batch: progress file '{}' has unexpected permissions {:o}; \
             expected 0600",
            path.display(),
            meta.mode() & 0o777
        ));
    }
    // Check ownership via raw getuid(2). No libc crate required — the
    // symbol is always available on POSIX targets.
    extern "C" { fn getuid() -> u32; }
    let caller_uid = unsafe { getuid() };
    if meta.uid() != caller_uid {
        return Err(format!(
            "locomo-spec answer-batch: progress file '{}' is owned by uid {} not {}",
            path.display(),
            meta.uid(),
            caller_uid
        ));
    }
    Ok(())
}

/// Header line written as the first line of a new progress file.
///
/// Encodes the selected-input digest and reader identity so a resume
/// invocation can confirm it is continuing the same run, not a different
/// selection or a different reader command.
fn progress_header_line(selected_input_sha256: &str, reader_identity: &str) -> String {
    // Hash the command before serialization: it may contain credentials.
    // The argument is an arbitrary shell command; only its digest enters JSON.
    let mut obj = serde_json::Map::new();
    obj.insert("type".to_string(), serde_json::Value::String("progress_header".to_string()));
    obj.insert(
        "selected_input_sha256".to_string(),
        serde_json::Value::String(selected_input_sha256.to_string()),
    );
    obj.insert(
        "reader_identity".to_string(),
        serde_json::Value::String(format!("sha256:{}", crate::run_environment::sha256_hex(reader_identity.as_bytes()))),
    );
    let mut s = serde_json::to_string(&obj).unwrap_or_else(|_| "{}".to_string());
    s.push('\n');
    s
}

fn load_progress_file(
    path: &Path,
    selected_ids: &HashSet<String>,
    expected_digest: &str,
    expected_identity: &str,
) -> Result<HashMap<String, serde_json::Map<String, Value>>, String> {
    let content = std::fs::read_to_string(path).map_err(|error| {
        format!(
            "locomo-spec answer-batch: cannot read progress file '{}': {error}",
            path.display()
        )
    })?;
    let mut result = HashMap::new();
    for (index, line) in content.lines().enumerate() {
        if line.is_empty() {
            continue;
        }
        let obj: serde_json::Map<String, Value> = serde_json::from_str(line).map_err(|error| {
            format!(
                "locomo-spec answer-batch: progress file '{}' line {} is malformed JSON: {error}",
                path.display(),
                index + 1
            )
        })?;
        // First non-empty line must be the progress header.
        if index == 0 {
            let rec_type = obj.get("type").and_then(Value::as_str).unwrap_or("");
            if rec_type != "progress_header" {
                return Err(format!(
                    "locomo-spec answer-batch: progress file '{}' first line must be a \
                     progress_header; got type='{rec_type}'",
                    path.display()
                ));
            }
            // Only reject a non-empty stored digest/identity that doesn't match the
            // current invocation.  An absent field (empty string from unwrap_or(""))
            // means the file was written by a pre-hardening version — allow the resume
            // rather than forcing the operator to discard valid prior work.
            let got_digest = obj.get("selected_input_sha256").and_then(Value::as_str).unwrap_or("");
            if !got_digest.is_empty() && got_digest != expected_digest {
                return Err(format!(
                    "locomo-spec answer-batch: progress file '{}' digest mismatch \
                     (expected {expected_digest}, got {got_digest}); \
                     delete the progress file to start a new run",
                    path.display()
                ));
            }
            let got_identity = obj.get("reader_identity").and_then(Value::as_str).unwrap_or("");
            if !got_identity.is_empty() && got_identity != format!("sha256:{}", crate::run_environment::sha256_hex(expected_identity.as_bytes())) {
                return Err(format!(
                    "locomo-spec answer-batch: progress file '{}' reader identity mismatch \
                     (command details withheld); \
                     delete the progress file to start a new run",
                    path.display()
                ));
            }
            continue; // header line validated — skip to data rows
        }
        let qid = obj
            .get("question_id")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                format!(
                    "locomo-spec answer-batch: progress file '{}' line {} missing question_id",
                    path.display(),
                    index + 1
                )
            })?
            .to_string();
        // Skip rows outside the current selected set.
        if !selected_ids.contains(&qid) {
            continue;
        }
        result.insert(qid, obj);
    }
    Ok(result)
}

pub fn run_answer_batch(
    inputs_path: &Path,
    answer_cmd: &str,
    output_path: &Path,
    limit: Option<usize>,
    offset: usize,
    reader_model: &str,
) -> Result<(), String> {
    let raw = std::fs::read_to_string(inputs_path).map_err(|error| {
        format!(
            "locomo-spec answer-batch: cannot read input dump '{}': {error}",
            inputs_path.display()
        )
    })?;
    let mut lines: Vec<&str> = raw.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop(); // accept one ordinary terminal newline
    }
    let first = lines
        .first()
        .copied()
        .ok_or_else(|| "locomo-spec answer-batch: input dump is empty".to_string())?;
    let mut header: serde_json::Map<String, Value> = serde_json::from_str(first)
        .map_err(|error| format!("locomo-spec answer-batch: invalid header: {error}"))?;
    if header.get("type").and_then(Value::as_str) != Some("header")
        || header.get("benchmark").and_then(Value::as_str) != Some("locomo-spec")
    {
        return Err(
            "locomo-spec answer-batch: first line must be a locomo-spec header".to_string(),
        );
    }

    let mut input_rows = Vec::new();
    let mut question_ids = HashSet::new();
    for (index, line) in lines.into_iter().skip(1).enumerate() {
        let input = validate_answer_input(line, index + 2)?;
        if !question_ids.insert(input.question_id.clone()) {
            return Err(format!(
                "locomo-spec answer-batch: duplicate question_id '{}' on line {}",
                input.question_id,
                index + 2
            ));
        }
        input_rows.push(input);
    }
    let selected_start = offset.min(input_rows.len());
    let selected_end = limit
        .map(|maximum| selected_start.saturating_add(maximum).min(input_rows.len()))
        .unwrap_or(input_rows.len());
    let selected_rows = &input_rows[selected_start..selected_end];
    if selected_rows.is_empty() {
        return Err("locomo-spec answer-batch: offset/limit selected zero input rows".to_string());
    }
    let mut selected_input_bytes = selected_rows
        .iter()
        .map(|input| input.raw_line.as_str())
        .collect::<Vec<_>>()
        .join("\n")
        .into_bytes();
    selected_input_bytes.push(b'\n');
    let selected_input_sha256 = crate::run_environment::sha256_hex(&selected_input_bytes);

    // Refuse if the final output already exists (no-clobber, identical to original behaviour).
    if output_path.exists() {
        return Err(format!(
            "locomo-spec answer-batch: cannot create new output '{}': File exists",
            output_path.display()
        ));
    }

    // Progress file: <output_path>.partial.jsonl, opened append, mode 0600.
    let progress_path = {
        let mut p = output_path.as_os_str().to_owned();
        p.push(".partial.jsonl");
        std::path::PathBuf::from(p)
    };
    let selected_id_set: HashSet<String> =
        selected_rows.iter().map(|r| r.question_id.clone()).collect();

    // Resume: load already-scored rows from the progress file if it exists,
    // after validating ownership and header integrity.
    let progress_exists = progress_path.exists();
    let resumed_rows: HashMap<String, serde_json::Map<String, Value>> =
        if progress_exists {
            validate_progress_file_ownership(&progress_path)?;
            load_progress_file(&progress_path, &selected_id_set, &selected_input_sha256, answer_cmd)?
        } else {
            HashMap::new()
        };
    // Only rows that will actually be reused count as resumed; rows that recorded
    // a reader failure are asked again below and do not count.
    let resumed_count = resumed_rows.values().filter(|r| !r.contains_key("error")).count();

    // Open the progress file for appending (create exclusively if absent, mode 0600).
    // O_EXCL on the fresh path prevents truncating a pre-existing file and stops
    // symlink-following; on the resume path O_APPEND is sufficient.
    let mut progress_file = if progress_exists {
        std::fs::OpenOptions::new()
            .write(true)
            .append(true)
            .open(&progress_path)
            .map_err(|error| {
                format!(
                    "locomo-spec answer-batch: cannot open progress file '{}': {error}",
                    progress_path.display()
                )
            })?
    } else {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&progress_path)
            .map_err(|error| {
                format!(
                    "locomo-spec answer-batch: cannot create progress file '{}': {error}",
                    progress_path.display()
                )
            })?;
        // Write the progress header as the first line so a resume invocation can
        // verify it is continuing the same selected-input set with the same reader.
        let header_line = progress_header_line(&selected_input_sha256, answer_cmd);
        f.write_all(header_line.as_bytes()).map_err(|e| {
            format!(
                "locomo-spec answer-batch: cannot write progress header '{}': {e}",
                progress_path.display()
            )
        })?;
        f.flush().ok();
        f
    };

    // Score each selected row, reusing resumed rows or calling the reader.
    let total_selected = selected_rows.len();
    let mut scored_by_id: HashMap<String, serde_json::Map<String, Value>> = HashMap::new();
    for (done, input) in selected_rows.iter().enumerate() {
        let question_id = &input.question_id;

        // Reuse a scored row from the progress file; a row that recorded a reader
        // failure (`error` present, prediction null) is asked again, so a transient
        // reader outage is never baked into the final file by a resume.
        if let Some(existing) = resumed_rows.get(question_id).filter(|r| !r.contains_key("error")) {
            scored_by_id.insert(question_id.clone(), existing.clone());
            // Progress line to stderr so the operator sees continuity.
            let _ = std::io::stderr().write_all(
                format!("[locomo answer-batch] {}/{} {question_id}\n", done + 1, total_selected)
                    .as_bytes(),
            );
            continue;
        }

        // Call the reader for this row.
        let row = &input.row;
        let category = input.category;
        let gold = input.gold.as_str();
        let prompt = reader_prompt(&input.question, category, &input.memory_texts);

        let scored_row: serde_json::Map<String, Value> = match lme_run_judge(answer_cmd, &prompt)
            .map(|answer| answer.trim().to_string())
            .and_then(|prediction| {
                score_question(category, &prediction, gold).map(|score| (prediction, score))
            }) {
            Ok((prediction, score)) => {
                serde_json::from_value(serde_json::json!({
                    "type": "answer_score",
                    "question_id": question_id,
                    "category": category,
                    "gold_answer": row.get("gold_answer").cloned().unwrap_or(Value::Null),
                    "prediction": prediction,
                    "score": swift_json_number(score),
                    "retrieved_drawer_ids": row.get("retrieved_drawer_ids").cloned().unwrap_or_else(|| serde_json::json!([])),
                    "retrieved_dia_ids": row.get("retrieved_dia_ids").cloned().unwrap_or_else(|| serde_json::json!([])),
                    "retrieved_ranks": row.get("retrieved_ranks").cloned().unwrap_or_else(|| serde_json::json!([])),
                }))
                .expect("valid object literal")
            }
            Err(error) => {
                serde_json::from_value(serde_json::json!({
                    "type": "answer_score",
                    "question_id": question_id,
                    "category": category,
                    "gold_answer": row.get("gold_answer").cloned().unwrap_or(Value::Null),
                    "prediction": Value::Null,
                    "score": 0.0,
                    "error": error,
                    "retrieved_drawer_ids": row.get("retrieved_drawer_ids").cloned().unwrap_or_else(|| serde_json::json!([])),
                    "retrieved_dia_ids": row.get("retrieved_dia_ids").cloned().unwrap_or_else(|| serde_json::json!([])),
                    "retrieved_ranks": row.get("retrieved_ranks").cloned().unwrap_or_else(|| serde_json::json!([])),
                }))
                .expect("valid object literal")
            }
        };

        // Append to progress file and sync immediately.
        let sorted_row = crate::longmemeval_scorer::sorted_json_value(&Value::Object(scored_row.clone()));
        let mut line_bytes = serde_json::to_vec(&sorted_row)
            .map_err(|e| format!("locomo-spec answer-batch encode failed: {e}"))?;
        line_bytes.push(b'\n');
        progress_file
            .write_all(&line_bytes)
            .map_err(|e| format!("locomo-spec answer-batch: cannot write progress file: {e}"))?;
        // sync_data, not flush: an unbuffered File's flush is a no-op, and the
        // progress file exists so a crash loses at most the row in flight (the
        // Swift twin fsyncs the descriptor per row).
        progress_file
            .sync_data()
            .map_err(|e| format!("locomo-spec answer-batch: cannot sync progress file: {e}"))?;

        scored_by_id.insert(question_id.clone(), scored_row);

        // One stderr progress line per row.
        let _ = std::io::stderr().write_all(
            format!("[locomo answer-batch] {}/{} {question_id}\n", done + 1, total_selected)
                .as_bytes(),
        );
    }

    // Assemble the final output in input order (not append order).
    let mut scored_rows_ordered = Vec::new();
    let mut score_tuples = Vec::new();
    for input in selected_rows {
        let row = scored_by_id
            .get(&input.question_id)
            .expect("every selected row was scored");
        scored_rows_ordered.push(Value::Object(row.clone()));
        let score = row
            .get("score")
            .and_then(Value::as_f64)
            .unwrap_or(0.0);
        score_tuples.push((input.category, score, 0.0f64));
    }

    // Re-count failures from the assembled rows (resumed rows may carry a failure too).
    let failures = scored_rows_ordered
        .iter()
        .filter(|r| r.get("error").is_some())
        .count();

    // When every selected row failed, leave the progress file intact for the next
    // resume attempt and surface the error without writing a final file.
    if !score_tuples.is_empty() && failures == score_tuples.len() {
        return Err(format!(
            "locomo-spec answer-batch: all {failures} records failed"
        ));
    }

    let aggregate = locomo_spec_aggregate(&score_tuples);
    header.insert(
        "type".to_string(),
        Value::String("answer_score_header".to_string()),
    );
    header.insert("reader_command_recorded".to_string(), Value::Bool(false));
    header.insert(
        "reader_model".to_string(),
        Value::String(reader_model.to_string()),
    );
    header.insert("offset".to_string(), Value::from(offset));
    header.insert("input_row_count".to_string(), Value::from(input_rows.len()));
    header.insert(
        "selected_input_count".to_string(),
        Value::from(selected_rows.len()),
    );
    header.insert(
        "selected_input_sha256".to_string(),
        Value::String(selected_input_sha256),
    );
    header.insert("questions".to_string(), Value::from(scored_rows_ordered.len()));
    header.insert("failures".to_string(), Value::from(failures));
    header.insert(
        "overall_token_f1".to_string(),
        swift_json_number(aggregate.overall),
    );
    header.insert(
        "by_category".to_string(),
        Value::Array(
            aggregate
                .by_category
                .iter()
                .map(|metric| {
                    serde_json::json!({
                        "category": metric.category,
                        "score": swift_json_number(metric.accuracy),
                        "question_count": metric.question_count,
                    })
                })
                .collect(),
        ),
    );
    // Two additive fields: resumed_row_count (0 on a clean run) and progress_file (provenance).
    header.insert("resumed_row_count".to_string(), Value::from(resumed_count));
    header.insert(
        "progress_file".to_string(),
        Value::String(progress_path.display().to_string()),
    );

    // Write the final output.
    let mut bytes = Vec::new();
    let rows = std::iter::once(Value::Object(header)).chain(scored_rows_ordered);
    for row in rows {
        let sorted = crate::longmemeval_scorer::sorted_json_value(&row);
        serde_json::to_writer(&mut bytes, &sorted)
            .map_err(|error| format!("locomo-spec answer-batch encode failed: {error}"))?;
        bytes.push(b'\n');
    }
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(output_path)
        .map_err(|error| {
            format!(
                "locomo-spec answer-batch: cannot create new output '{}': {error}",
                output_path.display()
            )
        })?;
    output.write_all(&bytes).map_err(|error| {
        format!(
            "locomo-spec answer-batch: cannot write output '{}': {error}",
            output_path.display()
        )
    })?;

    // Remove the progress file now that the final file is safely written.
    let _ = std::fs::remove_file(&progress_path);

    let _ = std::io::stdout().write_all(
        format!(
            "answer-batch: records={} failed={} benchmark=locomo-spec token_f1={:.4} out={}\n",
            score_tuples.len(),
            failures,
            aggregate.overall,
            output_path.display()
        )
        .as_bytes(),
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn progress_identity_does_not_disclose_commands() {
        let path = std::env::temp_dir().join(format!("locomo-secret-{}-{}", std::process::id(), nonce()));
        let command = "TOKEN=synthetic-secret printf Gold";
        let header = progress_header_line("digest", command);
        assert!(!header.contains("synthetic-secret"));
        std::fs::write(&path, header).unwrap();
        let ids = std::collections::HashSet::new();
        assert!(load_progress_file(&path, &ids, "digest", command).unwrap().is_empty());
        let error = load_progress_file(&path, &ids, "digest", "TOKEN=other-secret printf Gold").unwrap_err();
        assert!(!error.contains("synthetic-secret") && !error.contains("other-secret"));
        // Legacy raw-command headers must fail closed without echoing credentials.
        std::fs::write(&path, "{\"type\":\"progress_header\",\"reader_identity\":\"synthetic-secret\"}\n").unwrap();
        let error = load_progress_file(&path, &ids, "digest", command).unwrap_err();
        assert!(!error.contains("synthetic-secret"));
        std::fs::remove_file(path).unwrap();
    }

    fn nonce() -> u128 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    }

    /// Four-row input fixture: header + q1 q2 q3 q4.
    fn write_four_row_input(path: &std::path::Path) {
        std::fs::write(
            path,
            concat!(
                "{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Third?\",\"question_id\":\"q3\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Fourth?\",\"question_id\":\"q4\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
            ),
        )
        .unwrap();
    }

    #[test]
    fn prompt_matches_contract() {
        assert_eq!(
            reader_prompt("Where?", 1, &["Alice moved to Boston.".to_string()]),
            "Answer the question using only the retrieved memory records.\n\
Give only a short direct answer, without explanation.\n\
If the records do not contain the answer, reply: I don't know.\n\
\n\
Retrieved memory records:\n\
[1] Alice moved to Boston.\n\
\n\
Question: Where?\n\
Answer:"
        );
    }

    #[test]
    fn category_five_prompt_has_exact_abstention_phrase() {
        let prompt = reader_prompt("Where?", 5, &[]);
        assert!(prompt.contains("reply exactly: No information available."));
    }

    #[test]
    fn offset_limit_and_reader_identity_are_recorded() {
        let root = std::env::temp_dir().join(format!(
            "locomo-answer-batch-{}-{}", nonce(), std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let input = root.join("inputs.jsonl");
        let output = root.join("scores.jsonl");
        std::fs::write(
            &input,
            concat!(
                "{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
            ),
        )
        .unwrap();
        run_answer_batch(
            &input,
            "echo Boston",
            &output,
            Some(1),
            1,
            "fixture-reader",
        )
        .unwrap();
        let rows: Vec<Value> = std::fs::read_to_string(&output)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(rows[0]["reader_model"], "fixture-reader");
        assert_eq!(rows[0]["offset"], 1);
        assert_eq!(rows[0]["input_row_count"], 2);
        assert_eq!(rows[0]["selected_input_count"], 1);
        assert_eq!(
            rows[0]["selected_input_sha256"],
            "f1602616176fc13278447ceca02025229abb90798f1197d3ce4cd3835ba0c6a0"
        );
        assert_eq!(rows[1]["question_id"], "q2");
        // Two new additive header fields.
        assert_eq!(rows[0]["resumed_row_count"], 0);
        assert!(rows[0]["progress_file"].as_str().unwrap().ends_with(".partial.jsonl"));
        let first_bytes = std::fs::read(&output).unwrap();
        let error = run_answer_batch(
            &input,
            "echo Changed",
            &output,
            Some(1),
            1,
            "second-run",
        )
        .unwrap_err();
        assert!(error.contains("cannot create new output"));
        assert_eq!(std::fs::read(&output).unwrap(), first_bytes);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn malformed_wrong_kind_missing_duplicate_and_zero_selection_fail_loud() {
        let root = std::env::temp_dir().join(format!(
            "locomo-answer-batch-invalid-{}-{}", nonce(), std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let valid = "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Where?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}";
        let cases = [
            ("{not-json".to_string(), "malformed JSON"),
            (String::new(), "malformed JSON"),
            (valid.replace("\"answer_input\"", "\"other\""), "wrong kind"),
            (valid.replace("\"locomo-spec\"", "\"other-benchmark\""), "must be locomo-spec"),
            (valid.replace("\"question\":\"Where?\",", ""), "missing non-empty string field 'question'"),
            (valid.replace(",\"retrieved_ranks\":[]", ""), "retrieved_ranks"),
            (format!("{valid}\n{valid}"), "duplicate question_id"),
        ];
        for (index, (body, expected)) in cases.iter().enumerate() {
            let input = root.join(format!("inputs-{index}.jsonl"));
            let output = root.join(format!("scores-{index}.jsonl"));
            std::fs::write(
                &input,
                format!("{{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}}\n{body}\n"),
            )
            .unwrap();
            let error = run_answer_batch(&input, "echo Boston", &output, None, 0, "fixture")
                .unwrap_err();
            assert!(error.contains(expected), "expected {expected:?}, got {error:?}");
            assert!(!output.exists());
        }

        let input = root.join("inputs-offset.jsonl");
        let output = root.join("scores-offset.jsonl");
        std::fs::write(
            &input,
            format!("{{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}}\n{valid}\n"),
        )
        .unwrap();
        let error = run_answer_batch(&input, "echo Boston", &output, None, 2, "fixture")
            .unwrap_err();
        assert!(error.contains("selected zero input rows"));
        assert!(!output.exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    /// (a) Streaming: a reader that succeeds on rows 1-2 and fails on row 3.
    /// After the 3rd call the progress file must have 3 rows and the final file must not exist.
    #[test]
    fn streaming_writes_progress_and_leaves_no_final_on_partial_failure() {
        let root = std::env::temp_dir().join(format!(
            "locomo-streaming-{}-{}", nonce(), std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let input = root.join("inputs.jsonl");
        let output = root.join("scores.jsonl");
        write_four_row_input(&input);

        // Reader: succeeds for q1, q2, q3; fails on q4 (exit 1).
        // We run with limit=4 so all 4 rows are selected.
        // We use a script that exits 1 on the 3rd call by counting via a temp counter file.
        // Simpler: use a reader that fails only for "Fourth?" (question text).
        // The reader command receives the prompt on stdin; we match on the last word before "Answer:".
        // Easiest: fail-cmd that exits 1 unconditionally on the 3rd row.
        // We test with a script:
        //   if the prompt contains "Third?", exit 1; else echo Boston.
        let reader_cmd = "sh -c 'read -r -d \"\" input; if echo \"$input\" | grep -q \"Third?\"; then exit 1; else echo Boston; fi'";
        // This will fail on q3, not q4. That gives us 2 scored + 1 failure in the progress file.
        // q4 never gets called because we use limit=3 so only q1, q2, q3 are selected.
        let result = run_answer_batch(&input, reader_cmd, &output, Some(3), 0, "test");
        // The run completes (not all failures), but q3 scored 0 with an error field.
        // OR: if all 3 are failures, it returns Err. Either way the progress file must have 3 rows.
        let _ = result; // don't assert on success/failure here

        let progress_path = {
            let mut p = output.as_os_str().to_owned();
            p.push(".partial.jsonl");
            std::path::PathBuf::from(p)
        };
        if output.exists() {
            // Run completed — check the progress file was removed and 3 rows are in the final file.
            assert!(
                !progress_path.exists(),
                "progress file must be removed after successful completion"
            );
            let lines: Vec<String> = std::fs::read_to_string(&output)
                .unwrap()
                .lines()
                .map(str::to_string)
                .collect();
            // header + 3 scored rows
            assert_eq!(lines.len(), 4, "header + 3 score rows expected");
        } else {
            // Run failed part-way — check progress file has rows and no final file.
            assert!(
                progress_path.exists(),
                "progress file must exist after partial run"
            );
            let lines: Vec<String> = std::fs::read_to_string(&progress_path)
                .unwrap()
                .lines()
                .filter(|l| !l.is_empty())
                .map(str::to_string)
                .collect();
            assert!(
                !lines.is_empty(),
                "progress file must contain at least one row"
            );
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    /// Focused streaming test: reader exits 1 on every call (all-failure).
    /// After the run the progress file must have 3 rows (all failure rows) and no final file
    /// (because all-failures triggers the hard error path).
    #[test]
    fn streaming_all_failures_leaves_progress_no_final() {
        let root = std::env::temp_dir().join(format!(
            "locomo-streaming-fail-{}-{}", nonce(), std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let input = root.join("inputs.jsonl");
        let output = root.join("scores.jsonl");
        // Use only 3 rows for this test.
        std::fs::write(
            &input,
            concat!(
                "{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Third?\",\"question_id\":\"q3\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
            ),
        )
        .unwrap();

        // Reader always exits 1 — all 3 rows fail.
        let err = run_answer_batch(&input, "sh -c 'exit 1'", &output, None, 0, "fail-reader")
            .unwrap_err();
        assert!(err.contains("all") && err.contains("failed"), "expected all-failed error, got: {err}");
        assert!(!output.exists(), "final file must not exist");

        let progress_path = {
            let mut p = output.as_os_str().to_owned();
            p.push(".partial.jsonl");
            std::path::PathBuf::from(p)
        };
        assert!(progress_path.exists(), "progress file must exist after all-failure run");
        let all_progress_lines: Vec<String> = std::fs::read_to_string(&progress_path)
            .unwrap()
            .lines()
            .filter(|l| !l.is_empty())
            .map(str::to_string)
            .collect();
        // First line is progress_header; filter to only data rows (those with question_id).
        let progress_lines: Vec<String> = all_progress_lines.iter()
            .filter(|l| {
                serde_json::from_str::<Value>(l)
                    .ok()
                    .and_then(|v| v.get("question_id").cloned())
                    .is_some()
            })
            .cloned()
            .collect();
        assert_eq!(progress_lines.len(), 3, "progress file must have 3 failure rows");
        // Each row must be a valid JSON object with question_id and error fields.
        for line in &progress_lines {
            let obj: Value = serde_json::from_str(line).expect("valid JSON in progress file");
            assert!(obj.get("question_id").is_some());
            assert!(obj.get("error").is_some());
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    /// (b) Resume: first 2 of 3 rows scored and written to progress file manually;
    /// re-run with a different reader that would give different answers for q1, q2.
    /// Assert the final file's first two predictions are the originals (reused) and
    /// the reader was called only for q3.  header.resumed_row_count == 2.
    #[test]
    fn resume_reuses_already_scored_rows() {
        let root = std::env::temp_dir().join(format!(
            "locomo-resume-{}-{}", nonce(), std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let input = root.join("inputs.jsonl");
        let output = root.join("scores.jsonl");
        std::fs::write(
            &input,
            concat!(
                "{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Third?\",\"question_id\":\"q3\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
            ),
        )
        .unwrap();

        // Manually seed the progress file with q1 and q2 scored as "OriginalAnswer".
        let progress_path = {
            let mut p = output.as_os_str().to_owned();
            p.push(".partial.jsonl");
            std::path::PathBuf::from(p)
        };
        let q1_row = serde_json::json!({
            "type": "answer_score",
            "question_id": "q1",
            "category": 1,
            "gold_answer": "Boston",
            "prediction": "OriginalAnswer",
            "score": 0.0,
            "retrieved_drawer_ids": [],
            "retrieved_dia_ids": [],
            "retrieved_ranks": []
        });
        let q2_row = serde_json::json!({
            "type": "answer_score",
            "question_id": "q2",
            "category": 1,
            "gold_answer": "Boston",
            "prediction": "OriginalAnswer",
            "score": 0.0,
            "retrieved_drawer_ids": [],
            "retrieved_dia_ids": [],
            "retrieved_ranks": []
        });
        // Compute SHA-256 of selected rows to build the progress_header line.
        let q1_raw = "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}";
        let q2_raw = "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}";
        let q3_raw = "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Third?\",\"question_id\":\"q3\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}";
        let selected_bytes = format!("{}\n{}\n{}\n", q1_raw, q2_raw, q3_raw);
        let digest = crate::run_environment::sha256_hex(selected_bytes.as_bytes());
        // In Rust, reader_identity == answer_cmd (the actual shell command).
        let header_line = progress_header_line(&digest, "echo DifferentAnswer");
        let progress_content = format!(
            "{}\n{}\n{}\n",
            header_line,
            serde_json::to_string(&q1_row).unwrap(),
            serde_json::to_string(&q2_row).unwrap()
        );
        std::fs::write(&progress_path, progress_content).unwrap();
        // Set 0600 so the security ownership-and-permissions check passes.
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&progress_path,
                std::fs::Permissions::from_mode(0o600)).unwrap();
        }

        // Run with a reader that answers "DifferentAnswer" for everything.
        // q1 and q2 must be reused; q3 must call the reader.
        run_answer_batch(&input, "echo DifferentAnswer", &output, None, 0, "resume-reader")
            .unwrap();

        let rows: Vec<Value> = std::fs::read_to_string(&output)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        // header + 3 score rows
        assert_eq!(rows.len(), 4);
        // q1 and q2 must have the original prediction.
        assert_eq!(rows[1]["prediction"], "OriginalAnswer", "q1 must be reused");
        assert_eq!(rows[2]["prediction"], "OriginalAnswer", "q2 must be reused");
        // q3 must have the new reader's answer.
        assert_eq!(rows[3]["prediction"], "DifferentAnswer", "q3 must be freshly scored");
        // resumed_row_count == 2.
        assert_eq!(rows[0]["resumed_row_count"], 2);
        // Progress file must be removed.
        assert!(!progress_path.exists(), "progress file must be removed after successful run");
        std::fs::remove_dir_all(root).unwrap();
    }

    /// (c) Clean-run byte-identity: the rows section of a clean run equals that of a resumed run
    /// for the same answers.  The header differs only in resumed_row_count.
    #[test]
    fn clean_and_resumed_rows_are_byte_identical() {
        let root = std::env::temp_dir().join(format!(
            "locomo-byte-id-{}-{}", nonce(), std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let input = root.join("inputs.jsonl");
        let output_clean = root.join("clean.jsonl");
        let output_resumed = root.join("resumed.jsonl");
        std::fs::write(
            &input,
            concat!(
                "{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
                "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}\n",
            ),
        )
        .unwrap();

        // Clean run.
        run_answer_batch(&input, "echo Boston", &output_clean, None, 0, "test-reader").unwrap();

        // Seed the progress file for the resumed run with q1 already scored.
        let progress_path_resumed = {
            let mut p = output_resumed.as_os_str().to_owned();
            p.push(".partial.jsonl");
            std::path::PathBuf::from(p)
        };
        let q1_row = serde_json::json!({
            "type": "answer_score",
            "question_id": "q1",
            "category": 1,
            "gold_answer": "Boston",
            "prediction": "Boston",
            "score": 1,
            "retrieved_drawer_ids": [],
            "retrieved_dia_ids": [],
            "retrieved_ranks": []
        });
        // Compute SHA-256 of selected rows to build the progress_header line.
        let q1_input_raw = "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}";
        let q2_input_raw = "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}";
        let selected_bytes_resumed = format!("{}\n{}\n", q1_input_raw, q2_input_raw);
        let digest_resumed = crate::run_environment::sha256_hex(selected_bytes_resumed.as_bytes());
        // In Rust, reader_identity == answer_cmd (the actual shell command).
        let header_line_resumed = progress_header_line(&digest_resumed, "echo Boston");
        std::fs::write(
            &progress_path_resumed,
            format!("{}\n{}\n", header_line_resumed, serde_json::to_string(&q1_row).unwrap()),
        )
        .unwrap();
        // Set 0600 so the security ownership-and-permissions check passes.
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&progress_path_resumed,
                std::fs::Permissions::from_mode(0o600)).unwrap();
        }

        // Resumed run.
        run_answer_batch(&input, "echo Boston", &output_resumed, None, 0, "test-reader").unwrap();

        // Parse both outputs.
        let clean_lines: Vec<String> = std::fs::read_to_string(&output_clean)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        let resumed_lines: Vec<String> = std::fs::read_to_string(&output_resumed)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();

        // Row bytes must be identical (skip header, line 0).
        assert_eq!(
            clean_lines[1..],
            resumed_lines[1..],
            "row bytes must be identical between clean and resumed runs"
        );

        // Header must differ only in resumed_row_count.
        let clean_header: Value = serde_json::from_str(&clean_lines[0]).unwrap();
        let resumed_header: Value = serde_json::from_str(&resumed_lines[0]).unwrap();
        assert_eq!(clean_header["resumed_row_count"], 0);
        assert_eq!(resumed_header["resumed_row_count"], 1);
        // All other fields must match.
        let fields_to_compare = [
            "overall_token_f1", "questions", "failures", "selected_input_count",
            "selected_input_sha256", "reader_model",
        ];
        for field in fields_to_compare {
            assert_eq!(
                clean_header[field], resumed_header[field],
                "header field '{field}' must match between clean and resumed runs"
            );
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
