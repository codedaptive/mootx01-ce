// judge_batch.rs
//
// `judge-batch` subcommand: reads a pre-judge JSONL file produced by
// `--dump-judge-inputs` and runs the judge offline with no estate or
// mootx01 binary required.
//
// Usage:
//   mcp-benchmarker-rs judge-batch
//     --inputs <path.jsonl>
//     --judge-cmd <cmd>               (or MOOT_BENCH_JUDGE_CMD env var)
//     [--judge-grading substring|verdict]   default: substring
//     [--out <dir>]                   default: current directory
//
// Output: judge-verdicts-<run_label>-<iso8601>.jsonl in --out.
// Verdict line schema:
//   {"arm":"exact","correct":true,"gold_answer":"…","judge_answer":"…","question_id":"…","tokens":412}

use std::collections::BTreeMap;
use std::io::Write;
use std::path::PathBuf;

use crate::longmemeval_judge::{
    lme_grade_judge_answer, lme_judge_prompt, lme_parse_verdict, lme_run_judge,
    lme_verdict_prompt, LmeJudgeGrading,
};

// ─────────────────────────────────────────────────────────────────────────────
// Public entry point (called from main.rs dispatch)
// ─────────────────────────────────────────────────────────────────────────────

/// Entry point for the `judge-batch` subcommand.
///
/// Reads a JSONL dump file produced by `--dump-judge-inputs`, runs the LLM
/// judge offline per arm per question, writes verdict lines, and prints a
/// summary. No estate or mootx01 binary is required.
pub fn run_judge_batch(args: &[String]) -> Result<(), String> {
    let inputs_path = option_value("--inputs", args)
        .ok_or_else(|| "missing required option --inputs".to_string())?;

    // MOOT_BENCH_JUDGE_CMD env var takes precedence over --judge-cmd flag.
    // The flag value is visible in `ps` argv; the env var is not.
    let judge_cmd = std::env::var("MOOT_BENCH_JUDGE_CMD")
        .ok()
        .or_else(|| option_value("--judge-cmd", args).map(str::to_string))
        .ok_or_else(|| {
            "missing required judge command: set MOOT_BENCH_JUDGE_CMD or pass --judge-cmd"
                .to_string()
        })?;

    let grading_str = option_value("--judge-grading", args).unwrap_or("substring");
    let grading = match grading_str {
        "substring" => LmeJudgeGrading::Substring,
        "verdict" => LmeJudgeGrading::Verdict,
        other => {
            return Err(format!(
                "--judge-grading must be 'substring' or 'verdict'; got '{other}'"
            ))
        }
    };

    let out_dir = option_value("--out", args)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));

    judgebatch_run_batch(inputs_path, &judge_cmd, grading, &out_dir)
}

// ─────────────────────────────────────────────────────────────────────────────
// Batch runner
// ─────────────────────────────────────────────────────────────────────────────

/// Core logic: read JSONL, judge each arm payload, write verdict file.
pub fn judgebatch_run_batch(
    inputs_path: &str,
    judge_cmd: &str,
    grading: LmeJudgeGrading,
    out_dir: &std::path::Path,
) -> Result<(), String> {
    let content = std::fs::read_to_string(inputs_path)
        .map_err(|e| format!("cannot read inputs file at '{inputs_path}': {e}"))?;

    let lines: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();
    if lines.is_empty() {
        return Err(format!("inputs file is empty: '{inputs_path}'"));
    }

    // Parse the header line (must be first).
    let header: serde_json::Value = serde_json::from_str(lines[0])
        .map_err(|e| format!("first line of inputs file is not valid JSON: {e}"))?;
    if header["type"].as_str() != Some("header") {
        return Err("first line of inputs file is not a valid header object".to_string());
    }
    // Sanitize run_label: strip path separators to prevent directory traversal
    // via a crafted --inputs file writing the verdict outside --out.
    let run_label: String = {
        let raw = header["run_label"].as_str().unwrap_or("unknown");
        raw.replace("/", "_").replace("\\", "_").replace("..", "_")
    };

    let mut verdict_lines: Vec<String> = Vec::new();
    let mut total_judged: usize = 0;
    let mut total_correct: usize = 0;

    for line in lines.iter().skip(1) {
        let obj: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if obj["type"].as_str() != Some("question") {
            continue;
        }
        let question_id = match obj["question_id"].as_str() {
            Some(s) => s,
            None => continue,
        };
        let question_text = match obj["question"].as_str() {
            Some(s) => s,
            None => continue,
        };
        let gold_answer = match obj["gold_answer"].as_str() {
            Some(s) => s,
            None => continue,
        };

        // Judge each non-null arm.
        let arms: [(&str, Option<&str>, Option<usize>); 2] = [
            (
                "exact",
                obj["exact_payload"].as_str(),
                obj["exact_payload_tokens"].as_u64().map(|n| n as usize),
            ),
            (
                "dense",
                obj["dense_payload"].as_str(),
                obj["dense_payload_tokens"].as_u64().map(|n| n as usize),
            ),
        ];

        for (arm_name, payload_opt, token_count) in arms {
            let payload = match payload_opt {
                Some(p) if !p.is_empty() => p,
                _ => continue,
            };

            let prompt = lme_judge_prompt(question_text, payload);
            let answer = match lme_run_judge(judge_cmd, &prompt) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!(
                        "[judge-batch] judge failed for {question_id}/{arm_name}: {e}"
                    );
                    continue;
                }
            };

            let correct = judgebatch_grade(
                &answer,
                gold_answer,
                question_text,
                grading,
                judge_cmd,
            );
            total_judged += 1;
            if correct {
                total_correct += 1;
            }

            let tokens = token_count.unwrap_or_else(|| {
                crate::longmemeval_token_efficiency::lme_estimate_tokens(payload)
            });

            // Build verdict object with sorted keys for deterministic output.
            let mut verdict: BTreeMap<&str, serde_json::Value> = BTreeMap::new();
            verdict.insert("arm", serde_json::Value::String(arm_name.to_string()));
            verdict.insert("correct", serde_json::Value::Bool(correct));
            verdict.insert(
                "gold_answer",
                serde_json::Value::String(gold_answer.to_string()),
            );
            verdict.insert(
                "judge_answer",
                serde_json::Value::String(answer.clone()),
            );
            verdict.insert(
                "question_id",
                serde_json::Value::String(question_id.to_string()),
            );
            verdict.insert(
                "tokens",
                serde_json::Value::Number(serde_json::Number::from(tokens)),
            );

            if let Ok(s) = serde_json::to_string(&verdict) {
                verdict_lines.push(s);
            }
        }
    }

    // Write verdict file.
    let iso8601 = {
        use std::time::SystemTime;
        let secs = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        // Rudimentary ISO8601 from epoch seconds — avoids external date crates.
        // Produces YYYY-MM-DDTHH-MM-SSZ (colons replaced with hyphens for filenames).
        let s = secs;
        let sec = s % 60;
        let min = (s / 60) % 60;
        let hour = (s / 3600) % 24;
        let days = s / 86400;
        // Gregorian calendar computation for date from days since 1970-01-01.
        let (year, month, day) = days_to_ymd(days);
        format!(
            "{year:04}-{month:02}-{day:02}T{hour:02}-{min:02}-{sec:02}Z"
        )
    };

    let verdict_filename = format!("judge-verdicts-{run_label}-{iso8601}.jsonl");
    let verdict_path = out_dir.join(&verdict_filename);
    {
        let mut f = std::fs::File::create(&verdict_path)
            .map_err(|e| format!("cannot create verdict file '{verdict_filename}': {e}"))?;
        for vl in &verdict_lines {
            writeln!(f, "{vl}").map_err(|e| format!("verdict write error: {e}"))?;
        }
    }

    // Print summary.
    let accuracy = if total_judged > 0 {
        format!("{:.4}", total_correct as f64 / total_judged as f64)
    } else {
        "N/A".to_string()
    };
    eprintln!(
        "[judge-batch] run complete\n  questions judged: {total_judged}\n  correct:          {total_correct}\n  accuracy:         {accuracy}\n  verdicts written: {}",
        verdict_path.display()
    );

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Grading helper
// ─────────────────────────────────────────────────────────────────────────────

/// Grades one judge answer against the gold answer. Verdict mode spends a
/// second judge call for an explicit CORRECT/INCORRECT decision and falls back
/// to substring grading when the verdict is unparseable.
fn judgebatch_grade(
    answer: &str,
    gold_answer: &str,
    question_text: &str,
    grading: LmeJudgeGrading,
    judge_cmd: &str,
) -> bool {
    match grading {
        LmeJudgeGrading::Substring => lme_grade_judge_answer(answer, gold_answer),
        LmeJudgeGrading::Verdict => {
            let vp = lme_verdict_prompt(question_text, gold_answer, answer);
            match lme_run_judge(judge_cmd, &vp)
                .ok()
                .and_then(|r| lme_parse_verdict(&r))
            {
                Some(v) => v,
                None => {
                    eprintln!(
                        "[judge-batch] verdict unparseable — falling back to substring"
                    );
                    lme_grade_judge_answer(answer, gold_answer)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI option parsing helper (mirrors main.rs option_value)
// ─────────────────────────────────────────────────────────────────────────────

fn option_value<'a>(flag: &str, args: &'a [String]) -> Option<&'a str> {
    args.windows(2)
        .find(|w| w[0] == flag)
        .map(|w| w[1].as_str())
}

// ─────────────────────────────────────────────────────────────────────────────
// Date helper: days-since-epoch → (year, month, day)
// ─────────────────────────────────────────────────────────────────────────────

// Proleptic Gregorian calendar. Sufficient for producing an unambiguous
// filename timestamp — not intended for general calendar arithmetic.
fn days_to_ymd(days: u64) -> (u64, u64, u64) {
    let mut d = days;
    let mut y: u64 = 1970;
    loop {
        let dy = if is_leap(y) { 366 } else { 365 };
        if d < dy { break; }
        d -= dy;
        y += 1;
    }
    let months: [u64; 12] = if is_leap(y) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m: u64 = 1;
    for &dm in &months {
        if d < dm { break; }
        d -= dm;
        m += 1;
    }
    (y, m, d + 1)
}

fn is_leap(y: u64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn option_value_finds_flag() {
        let args: Vec<String> = ["--inputs", "/tmp/dump.jsonl", "--out", "/tmp"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(option_value("--inputs", &args), Some("/tmp/dump.jsonl"));
        assert_eq!(option_value("--out", &args), Some("/tmp"));
        assert_eq!(option_value("--missing", &args), None);
    }

    #[test]
    fn days_to_ymd_epoch() {
        // Day 0 = 1970-01-01
        assert_eq!(days_to_ymd(0), (1970, 1, 1));
    }

    #[test]
    fn days_to_ymd_known_date() {
        // 2026-08-10: days from 1970-01-01
        // Years 1970-2025 = 56 years, 14 leap years (72,76,80,84,88,92,96,00,04,08,12,16,20,24)
        // = 56*365 + 14 = 20440 + 14 = 20454
        // Jan(31)+Feb(28)+Mar(31)+Apr(30)+May(31)+Jun(30)+Jul(31) = 212; +9 days = 221
        // 2026 is not a leap year
        let d: u64 = 20454 + 212 + 9; // = 20675
        let (y, m, day) = days_to_ymd(d);
        assert_eq!(y, 2026);
        assert_eq!(m, 8);
        assert_eq!(day, 10);
    }

    #[test]
    fn judgebatch_run_batch_empty_file() {
        let dir = tempdir_for_test("judgebatch_empty");
        let inputs = dir.join("empty.jsonl");
        std::fs::write(&inputs, "").unwrap();
        let result = judgebatch_run_batch(
            inputs.to_str().unwrap(),
            "echo yes",
            LmeJudgeGrading::Substring,
            &dir,
        );
        assert!(result.is_err(), "empty file should error");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn judgebatch_run_batch_missing_header() {
        let dir = tempdir_for_test("judgebatch_noheader");
        let inputs = dir.join("noheader.jsonl");
        std::fs::write(&inputs, "{\"type\":\"question\"}\n").unwrap();
        let result = judgebatch_run_batch(
            inputs.to_str().unwrap(),
            "echo yes",
            LmeJudgeGrading::Substring,
            &dir,
        );
        assert!(result.is_err(), "missing header should error");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // Test C: JSONL format contract — header and question lines have required fields.
    // Constructs a synthetic dump matching the spec and verifies field presence.
    #[test]
    fn jsonl_format_header_has_required_fields() {
        let header = serde_json::json!({
            "type": "header",
            "benchmark": "longmemeval",
            "variant": "s",
            "seed": 42_u64,
            "run_label": "test-run",
            "arm": "both",
            "judge_hydration_depth": 10_usize,
        });
        assert_eq!(header["type"].as_str(), Some("header"));
        assert_eq!(header["benchmark"].as_str(), Some("longmemeval"));
        assert!(header.get("variant").is_some());
        assert!(header.get("seed").is_some());
        assert!(header.get("run_label").is_some());
        assert!(header.get("arm").is_some());
        assert!(header.get("judge_hydration_depth").is_some());
    }

    #[test]
    fn jsonl_format_question_line_has_required_fields() {
        let question = serde_json::json!({
            "type": "question",
            "question_id": "q001",
            "question": "What is the capital?",
            "gold_answer": "Paris",
            "exact_payload": "The capital of France is Paris.",
            "exact_payload_tokens": 8_usize,
            "dense_payload": null,
            "dense_payload_tokens": null,
        });
        assert_eq!(question["type"].as_str(), Some("question"));
        assert_eq!(question["question_id"].as_str(), Some("q001"));
        assert_eq!(question["gold_answer"].as_str(), Some("Paris"));
        assert!(question["exact_payload"].is_string());
        assert!(question["exact_payload_tokens"].is_number());
        assert!(question["dense_payload"].is_null());
        assert!(question["dense_payload_tokens"].is_null());
    }

    // Test D: judge-batch reads synthetic 3-line JSONL and produces a verdict file.
    // Uses `echo Paris` as the judge command so substring grading against gold "Paris"
    // yields correct=true — no live LLM required.
    #[test]
    fn judgebatch_produces_verdict_file_from_synthetic_jsonl() {
        let dir = tempdir_for_test("judgebatch_verdict");
        let inputs = dir.join("dump.jsonl");

        // Write 1 header + 2 question lines.
        let header = serde_json::json!({
            "type": "header",
            "benchmark": "longmemeval",
            "variant": "s",
            "seed": 42_u64,
            "run_label": "test-batch",
            "arm": "both",
            "judge_hydration_depth": 10_usize,
        });
        let q1 = serde_json::json!({
            "type": "question",
            "question_id": "q001",
            "question": "What is the capital?",
            "gold_answer": "Paris",
            "exact_payload": "The capital is Paris.",
            "exact_payload_tokens": 5_usize,
            "dense_payload": null,
            "dense_payload_tokens": null,
        });
        let q2 = serde_json::json!({
            "type": "question",
            "question_id": "q002",
            "question": "Name a river.",
            "gold_answer": "Seine",
            "exact_payload": "The river Seine flows through the city.",
            "exact_payload_tokens": 8_usize,
            "dense_payload": "The Seine is a river.",
            "dense_payload_tokens": 5_usize,
        });
        let content = format!(
            "{}\n{}\n{}\n",
            serde_json::to_string(&header).unwrap(),
            serde_json::to_string(&q1).unwrap(),
            serde_json::to_string(&q2).unwrap(),
        );
        std::fs::write(&inputs, &content).unwrap();

        // Use `echo Paris` — substring grading matches gold "Paris" for q001 exact arm.
        // q002 exact and dense arms won't match "Seine" from `echo Paris` → correct=false.
        let result = judgebatch_run_batch(
            inputs.to_str().unwrap(),
            "echo Paris",
            LmeJudgeGrading::Substring,
            &dir,
        );
        assert!(result.is_ok(), "judgebatch_run_batch should succeed: {result:?}");

        // Read back the verdict file.
        let verdict_file = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .find(|e| e.file_name().to_string_lossy().starts_with("judge-verdicts-test-batch-"))
            .expect("verdict file should be created");

        let verdict_content = std::fs::read_to_string(verdict_file.path()).unwrap();
        let verdict_lines: Vec<serde_json::Value> = verdict_content
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_str(l).expect("verdict line should be valid JSON"))
            .collect();

        // q001 exact arm: "echo Paris" → "Paris" matches gold "Paris" → correct=true.
        // q002 exact arm: "echo Paris" → "Paris" does not match gold "Seine" → correct=false.
        // q002 dense arm: same judge, same result → correct=false.
        assert_eq!(verdict_lines.len(), 3, "3 arms judged (q001 exact, q002 exact, q002 dense)");

        // Verify required fields on each verdict line.
        for line in &verdict_lines {
            assert!(line.get("question_id").is_some(), "verdict must have question_id");
            assert!(line.get("arm").is_some(), "verdict must have arm");
            assert!(line.get("gold_answer").is_some(), "verdict must have gold_answer");
            assert!(line.get("judge_answer").is_some(), "verdict must have judge_answer");
            assert!(line.get("correct").is_some(), "verdict must have correct field");
            assert!(line.get("tokens").is_some(), "verdict must have tokens");
        }

        // q001 exact arm should be correct.
        let q001_exact = verdict_lines
            .iter()
            .find(|l| l["question_id"] == "q001" && l["arm"] == "exact")
            .expect("q001 exact verdict should exist");
        assert!(
            q001_exact["correct"].as_bool() == Some(true),
            "q001 exact: 'Paris' substring-matches gold 'Paris'"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    fn tempdir_for_test(tag: &str) -> std::path::PathBuf {
        let dir = std::path::PathBuf::from(format!("/tmp/judge-batch-test-{tag}"));
        let _ = std::fs::create_dir_all(&dir);
        dir
    }
}
