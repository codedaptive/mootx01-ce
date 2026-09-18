// lme_spec_answer_batch.rs — Offline reader-model consumer for lme-spec answer-input dumps.
//
// Reads the JSONL dump produced by `lme-spec --dump-answer-inputs`, runs a
// reader model subprocess for each question (via the same lme_run_judge seam
// used by the inline judge path), builds the §2 anscheck prompt from the
// reader's answer, and writes judge_ready JSONL lines consumed by
// judge-sessions.py unchanged.
//
// Pipeline position:
//   lme-spec --dump-answer-inputs answers.jsonl
//   answer-batch --inputs answers.jsonl --answer-cmd "..." --out judge_ready.jsonl
//   judge-sessions.py (consumes judge_ready.jsonl unchanged)
//
// Per-record failures (reader command failed or returned empty) are written as:
//   {"error":…,"hypothesis":null,"question_id":…}

use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;

use serde_json::Value as JsonValue;

use crate::lme_spec_grader::anscheck_prompt;
use crate::longmemeval_judge::lme_run_judge;

/// Builds the reader prompt for lme-spec answer-batch.
///
/// Presents the retrieved memory texts to the reader model, followed by the
/// question, asking for a direct prose answer.
///
/// Twin of Swift `lmeSpecReaderPrompt` in `LMESpecAnswerBatch.swift`.
pub fn lme_spec_reader_prompt(question: &str, memory_texts: &[String]) -> String {
    let mut parts: Vec<String> = Vec::new();
    parts.push("You are answering a question based on retrieved memory records.".to_string());
    parts.push("Read all records carefully and give a direct, concise answer.".to_string());
    parts.push("If the records do not contain the answer, say \"I don't know.\"".to_string());
    parts.push(String::new());

    if memory_texts.is_empty() {
        parts.push("No memory records were retrieved for this question.".to_string());
    } else {
        parts.push("Retrieved memory records:".to_string());
        parts.push(String::new());
        for (i, text) in memory_texts.iter().enumerate() {
            parts.push(format!("{}. {}", i + 1, text));
        }
    }

    parts.push(String::new());
    parts.push(format!("Question: {question}"));
    parts.push(String::new());
    parts.push("Answer:".to_string());
    parts.join("\n")
}

/// Reads a lme-spec answer-input JSONL dump, runs the reader model for each
/// question, builds the §2 anscheck prompt, and writes judge_ready JSONL lines.
///
/// The output is consumed by judge-sessions.py unchanged —
/// the anscheck_prompt field is byte-exact from the per-type anscheck builder.
///
/// - `inputs_path`: lme-spec answer-input JSONL with header `benchmark="lme-spec"`.
/// - `answer_cmd`: shell command for the reader model (stdin = prompt, stdout = answer).
/// - `output_path`: output JSONL path (created 0o600; must not already exist).
/// - `judge_model`: model identifier copied into judge_ready lines.
///
/// Twin of Swift `runLMESpecAnswerBatch` in `LMESpecAnswerBatch.swift`.
pub fn run_lme_spec_answer_batch(
    inputs_path: &Path,
    answer_cmd: &str,
    output_path: &Path,
    judge_model: &str,
) -> Result<(), String> {
    let raw = std::fs::read_to_string(inputs_path)
        .map_err(|e| format!("lme-spec answer-batch: cannot read '{}': {e}", inputs_path.display()))?;

    let lines: Vec<&str> = raw.split('\n').filter(|l| !l.is_empty()).collect();
    if lines.is_empty() {
        return Err(format!(
            "lme-spec answer-batch: input dump is empty: '{}'", inputs_path.display()
        ));
    }

    // Validate header.
    let header: serde_json::Map<String, JsonValue> = serde_json::from_str(lines[0])
        .map_err(|e| format!("lme-spec answer-batch: header is not valid JSON: {e}"))?;
    if header.get("type").and_then(JsonValue::as_str) != Some("header") {
        return Err("lme-spec answer-batch: first line must have type=header".to_string());
    }
    if header.get("benchmark").and_then(JsonValue::as_str) != Some("lme-spec") {
        return Err("lme-spec answer-batch: header must have benchmark=lme-spec".to_string());
    }

    // Compute the selected-input digest over all answer_input lines.
    // Used in the output header so a resume invocation can confirm it is
    // continuing the same run with the same inputs and reader identity.
    let answer_input_bytes: Vec<u8> = lines.iter().skip(1)
        .filter(|l| {
            serde_json::from_str::<serde_json::Map<String, JsonValue>>(l)
                .ok()
                .and_then(|m| m.get("type").and_then(JsonValue::as_str).map(|t| t == "answer_input"))
                .unwrap_or(false)
        })
        .flat_map(|l| l.as_bytes().iter().copied().chain(std::iter::once(b'\n')))
        .collect();
    let selected_input_sha256 = crate::run_environment::sha256_hex(&answer_input_bytes);

    // Resume: collect question_ids already answered in the output file. Records
    // with a non-null hypothesis were written by a previous run and should not
    // be re-answered: re-running the reader wastes time and risks replacing a
    // good answer when the shared server is degraded.
    let output_path_str = output_path.to_string_lossy().to_string();
    let output_exists = output_path.exists();

    // On resume: validate ownership (regular file, owned by caller, mode 0600)
    // and confirm the header's digest and reader identity match this invocation.
    if output_exists {
        use std::os::unix::fs::MetadataExt;
        let meta = std::fs::metadata(output_path)
            .map_err(|e| format!("lme-spec answer-batch: cannot stat output '{}': {e}", output_path_str))?;
        if !meta.file_type().is_file() {
            return Err(format!(
                "lme-spec answer-batch: output '{}' is not a regular file", output_path_str));
        }
        if meta.mode() & 0o777 != 0o600 {
            return Err(format!(
                "lme-spec answer-batch: output '{}' has unexpected permissions {:o}; expected 0600",
                output_path_str, meta.mode() & 0o777));
        }
        extern "C" { fn getuid() -> u32; }
        let caller_uid = unsafe { getuid() };
        if meta.uid() != caller_uid {
            return Err(format!(
                "lme-spec answer-batch: output '{}' is not owned by the current user",
                output_path_str));
        }
        // Validate digest and reader identity from the output header.
        if let Ok(existing) = std::fs::read_to_string(output_path) {
            if let Some(first_line) = existing.split('\n').find(|l| !l.is_empty()) {
                if let Ok(ev) = serde_json::from_str::<serde_json::Map<String, JsonValue>>(first_line) {
                    let got_digest = ev.get("selected_input_sha256").and_then(JsonValue::as_str).unwrap_or("");
                    if !got_digest.is_empty() && got_digest != selected_input_sha256 {
                        return Err(format!(
                            "lme-spec answer-batch: output '{}' digest mismatch \
                             (expected {selected_input_sha256}, got {got_digest}); \
                             delete the output file to start a new run",
                            output_path_str));
                    }
                    let got_identity = ev.get("reader_identity").and_then(JsonValue::as_str).unwrap_or("");
                    if !got_identity.is_empty() && got_identity != format!("sha256:{}", crate::run_environment::sha256_hex(answer_cmd.as_bytes())) {
                        return Err(format!(
                            "lme-spec answer-batch: output '{}' reader identity mismatch; \
                             delete the output file to start a new run",
                            output_path_str));
                    }
                }
            }
        }
    }

    let mut resumed_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
    if output_exists {
        if let Ok(existing) = std::fs::read_to_string(output_path) {
            for eline in existing.split('\n').filter(|l| !l.is_empty()) {
                if let Ok(ev) = serde_json::from_str::<serde_json::Map<String, JsonValue>>(eline) {
                    if let Some(qid) = ev.get("question_id").and_then(JsonValue::as_str) {
                        // A record is resumed only if hypothesis is non-null.
                        let hyp = ev.get("hypothesis");
                        let is_answered = hyp.map(|v| !v.is_null()).unwrap_or(false);
                        if is_answered {
                            resumed_ids.insert(qid.to_string());
                        }
                    }
                }
            }
        }
    }
    let resumed_count = resumed_ids.len();

    // Open for append (create exclusively with 0o600 when absent — O_EXCL prevents
    // truncation of an existing file and symlink following).
    if !output_exists {
        crate::lme_spec_runner::write_owner_only_file(output_path, b"");
    }
    let mut out_file = std::fs::OpenOptions::new()
        .write(true)
        .append(true)
        .open(output_path)
        .map_err(|e| format!("lme-spec answer-batch: cannot open output '{}': {e}", output_path_str))?;

    // Write output header on a fresh file only; on resume the header is already present.
    if !output_exists {
        let mut out_header = header.clone();
        out_header.insert("judge_model".to_string(), JsonValue::String(judge_model.to_string()));
        // Embed selected-input digest and reader identity for resume validation.
        out_header.insert("selected_input_sha256".to_string(), JsonValue::String(selected_input_sha256.clone()));
        // Commands may contain credentials. Persist only an opaque resume key.
        out_header.insert("reader_identity".to_string(), JsonValue::String(format!("sha256:{}", crate::run_environment::sha256_hex(answer_cmd.as_bytes()))));
        let sorted: BTreeMap<&str, &JsonValue> = out_header.iter().map(|(k, v)| (k.as_str(), v)).collect();
        if let Ok(s) = serde_json::to_string(&sorted) {
            let _ = writeln!(out_file, "{s}");
        }
    }

    let mut failure_count: usize = 0;

    for line in lines.iter().skip(1) {
        let obj: serde_json::Map<String, JsonValue> = match serde_json::from_str(line) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if obj.get("type").and_then(JsonValue::as_str) != Some("answer_input") {
            continue;
        }

        let question_id = match obj.get("question_id").and_then(JsonValue::as_str) {
            Some(s) => s.to_string(),
            None => continue,
        };

        // Resume: skip records already answered in a prior run.
        if resumed_ids.contains(&question_id) { continue; }

        let question_type = obj.get("question_type").and_then(JsonValue::as_str)
            .unwrap_or("").to_string();
        let base_question_type = obj.get("base_question_type").and_then(JsonValue::as_str)
            .unwrap_or(&question_type).to_string();
        let is_abstention = obj.get("is_abstention").and_then(JsonValue::as_bool)
            .unwrap_or_else(|| question_id.contains("_abs"));
        let question = match obj.get("question").and_then(JsonValue::as_str) {
            Some(s) => s.to_string(),
            None => continue,
        };
        let correct_answer = match obj.get("correct_answer").and_then(JsonValue::as_str) {
            Some(s) => s.to_string(),
            None => continue,
        };
        let memory_texts: Vec<String> = obj.get("memory_texts")
            .and_then(JsonValue::as_array)
            .map(|arr| arr.iter().filter_map(JsonValue::as_str).map(str::to_string).collect())
            .unwrap_or_default();
        let prompt = lme_spec_reader_prompt(&question, &memory_texts);

        let reader_answer = match lme_run_judge(answer_cmd, &prompt) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("[lme-spec answer-batch] reader cmd failed for {question_id}: {e}");
                failure_count += 1;
                let mut fail: BTreeMap<&str, JsonValue> = BTreeMap::new();
                fail.insert("error", JsonValue::String(e.clone()));
                fail.insert("hypothesis", JsonValue::Null);
                fail.insert("question_id", JsonValue::String(question_id.clone()));
                if let Ok(s) = serde_json::to_string(&fail) {
                    let _ = writeln!(out_file, "{s}");
                }
                continue;
            }
        };

        // Build the §2 anscheck prompt from the reader's answer.
        let question_type_for_anscheck = if is_abstention {
            format!("{base_question_type}_abs")
        } else {
            base_question_type.clone()
        };
        let anscheck = match anscheck_prompt(&question_type_for_anscheck, &question_id, &question, &correct_answer, &reader_answer) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("[lme-spec answer-batch] anscheck prompt failed for {question_id}: {e}");
                failure_count += 1;
                let mut fail: BTreeMap<&str, JsonValue> = BTreeMap::new();
                fail.insert("error", JsonValue::String(format!("{e}")));
                fail.insert("hypothesis", JsonValue::Null);
                fail.insert("question_id", JsonValue::String(question_id.clone()));
                if let Ok(s) = serde_json::to_string(&fail) {
                    let _ = writeln!(out_file, "{s}");
                }
                continue;
            }
        };

        // Write the judge_ready line.
        let mut jr: BTreeMap<&str, JsonValue> = BTreeMap::new();
        jr.insert("anscheck_prompt", JsonValue::String(anscheck));
        jr.insert("base_question_type", JsonValue::String(base_question_type));
        jr.insert("hypothesis", JsonValue::String(reader_answer));
        jr.insert("is_abstention", JsonValue::Bool(is_abstention));
        jr.insert("max_tokens", JsonValue::Number(serde_json::Number::from(10u64)));
        jr.insert("model", JsonValue::String(judge_model.to_string()));
        jr.insert("n", JsonValue::Number(serde_json::Number::from(1u64)));
        jr.insert("question_id", JsonValue::String(question_id));
        jr.insert("temperature", JsonValue::Number(serde_json::Number::from(0u64)));
        jr.insert("type", JsonValue::String("judge_ready".to_string()));
        if let Ok(s) = serde_json::to_string(&jr) {
            let _ = writeln!(out_file, "{s}");
        }
    }

    if failure_count > 0 {
        eprintln!("[lme-spec answer-batch] {failure_count} record(s) failed — see error lines in output");
    }
    if resumed_count > 0 {
        eprintln!("[lme-spec answer-batch] {resumed_count} record(s) skipped (already answered in prior run)");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opaque_reader_resume_identity() {
        let dir = std::env::temp_dir().join(format!("lme-secret-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let input = dir.join("input.jsonl");
        let output = dir.join("output.jsonl");
        std::fs::write(&input, "{\"type\":\"header\",\"benchmark\":\"lme-spec\"}\n").unwrap();
        let command = "TOKEN=synthetic-secret printf Gold";
        run_lme_spec_answer_batch(&input, command, &output, "test").unwrap();
        let before = std::fs::read_to_string(&output).unwrap();
        assert!(!before.contains("synthetic-secret"));
        assert!(before.contains(&format!("sha256:{}", crate::run_environment::sha256_hex(command.as_bytes()))));
        run_lme_spec_answer_batch(&input, command, &output, "test").unwrap();
        assert_eq!(std::fs::read_to_string(&output).unwrap(), before);
        let error = run_lme_spec_answer_batch(&input, "TOKEN=other-secret printf Gold", &output, "test").unwrap_err();
        assert!(!error.contains("synthetic-secret") && !error.contains("other-secret"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn reader_prompt_builds_correctly() {
        let prompt = lme_spec_reader_prompt("What color is the sky?", &["The sky is blue.".to_string()]);
        assert!(prompt.contains("Retrieved memory records:"));
        assert!(prompt.contains("1. The sky is blue."));
        assert!(prompt.contains("Question: What color is the sky?"));
        assert!(!prompt.contains("Additional context:"));
    }

    #[test]
    fn answer_batch_judge_ready_shape() {
        use std::io::Write as _;
        let dir = std::env::temp_dir().join(format!("lmerd_ab_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        // Build a minimal answer_input dump.
        let header = r#"{"benchmark":"lme-spec","run_label":"test","seed":0,"type":"header","variant":"s"}"#;
        let record = r#"{"base_question_type":"single-session-user","benchmark":"lme-spec","correct_answer":"Blue","hypothesis_digest":null,"is_abstention":false,"memory_texts":[],"question":"What color?","question_date":"2023-01-01","question_id":"q001","question_type":"single-session-user","retrieved_drawer_ids":[],"type":"answer_input"}"#;

        let inputs_path = dir.join("inputs.jsonl");
        let mut f = std::fs::File::create(&inputs_path).unwrap();
        writeln!(f, "{header}").unwrap();
        writeln!(f, "{record}").unwrap();
        drop(f);

        let output_path = dir.join("out.jsonl");
        // Use 'printf "Blue"' as a deterministic reader command.
        run_lme_spec_answer_batch(
            &inputs_path,
            "sh -c 'printf Blue'",
            &output_path,
            "gpt-4o-2024-08-06",
        ).unwrap();

        let out = std::fs::read_to_string(&output_path).unwrap();
        let out_lines: Vec<&str> = out.lines().collect();
        assert_eq!(out_lines.len(), 2, "header + 1 judge_ready line");

        let record_obj: serde_json::Value = serde_json::from_str(out_lines[1]).unwrap();
        assert_eq!(record_obj["type"], "judge_ready");
        assert_eq!(record_obj["question_id"], "q001");
        assert!(record_obj["anscheck_prompt"].as_str().unwrap().len() > 10);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
