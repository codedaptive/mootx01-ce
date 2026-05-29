// Wire format types per QUEUEKIT_SPEC §6 and §7.
//
// The substrate HLC type is consumed from substrate-lib (the
// canonical home per M1; field names match this kit's spec §6
// snake_case wire format exactly). QueueKit's hand-built JSON
// encoder (hlc_value, below) writes the spec's snake_case keys
// rather than substrate-lib's default camelCase Codable shape —
// the wire format here is intentionally distinct from substrate-
// lib's canonical wire format. Byte-identity against the Swift
// port is gated by tests/conformance.rs.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
pub use substrate_lib::hlc::HLC;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct JobId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StreamId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SessionId(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ObservationStatus {
    Running,
    Done,
    DoneWithConcerns,
    NeedsContext,
    Blocked,
}

impl ObservationStatus {
    pub fn raw(&self) -> &'static str {
        match self {
            ObservationStatus::Running => "running",
            ObservationStatus::Done => "done",
            ObservationStatus::DoneWithConcerns => "done_with_concerns",
            ObservationStatus::NeedsContext => "needs_context",
            ObservationStatus::Blocked => "blocked",
        }
    }

    pub fn from_raw(s: &str) -> Option<Self> {
        Some(match s {
            "running" => ObservationStatus::Running,
            "done" => ObservationStatus::Done,
            "done_with_concerns" => ObservationStatus::DoneWithConcerns,
            "needs_context" => ObservationStatus::NeedsContext,
            "blocked" => ObservationStatus::Blocked,
            _ => return None,
        })
    }

    pub fn is_terminal(&self) -> bool {
        !matches!(self, ObservationStatus::Running)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ArtifactRef {
    FilePath(String),
    CommitHash(String),
    SignalFile(String),
    TrajectoryStepId(String),
}

impl ArtifactRef {
    pub fn type_tag(&self) -> &'static str {
        match self {
            ArtifactRef::FilePath(_) => "file_path",
            ArtifactRef::CommitHash(_) => "commit_hash",
            ArtifactRef::SignalFile(_) => "signal_file",
            ArtifactRef::TrajectoryStepId(_) => "trajectory_step_id",
        }
    }
    pub fn value(&self) -> &str {
        match self {
            ArtifactRef::FilePath(v)
            | ArtifactRef::CommitHash(v)
            | ArtifactRef::SignalFile(v)
            | ArtifactRef::TrajectoryStepId(v) => v,
        }
    }
}

/// CodableValue mirrors the Swift CodableValue. We keep it as a
/// serde_json::Value for simplicity.
pub type CodableValue = Value;

#[derive(Debug, Clone)]
pub struct Job {
    pub id: JobId,
    pub stream_id: StreamId,
    pub submitted_at: HLC,
    pub priority: i32,
    pub payload: Vec<u8>,
    pub extensions: Map<String, CodableValue>,
}

#[derive(Debug, Clone)]
pub struct SignalFile {
    pub job_id: JobId,
    pub status: ObservationStatus,
    pub artifacts: Vec<ArtifactRef>,
    pub completed_at: HLC,
}

// -------------------------------------------------------------
// base64url, no padding (RFC 4648 §5)
// -------------------------------------------------------------

const B64_ALPHABET: &[u8] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub fn base64url_encode(data: &[u8]) -> String {
    let mut out = String::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        let b0 = data[i] as u32;
        let b1 = data[i + 1] as u32;
        let b2 = data[i + 2] as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(B64_ALPHABET[((triple >> 18) & 63) as usize] as char);
        out.push(B64_ALPHABET[((triple >> 12) & 63) as usize] as char);
        out.push(B64_ALPHABET[((triple >> 6) & 63) as usize] as char);
        out.push(B64_ALPHABET[(triple & 63) as usize] as char);
        i += 3;
    }
    let rem = data.len() - i;
    if rem == 1 {
        let b0 = data[i] as u32;
        let triple = b0 << 16;
        out.push(B64_ALPHABET[((triple >> 18) & 63) as usize] as char);
        out.push(B64_ALPHABET[((triple >> 12) & 63) as usize] as char);
    } else if rem == 2 {
        let b0 = data[i] as u32;
        let b1 = data[i + 1] as u32;
        let triple = (b0 << 16) | (b1 << 8);
        out.push(B64_ALPHABET[((triple >> 18) & 63) as usize] as char);
        out.push(B64_ALPHABET[((triple >> 12) & 63) as usize] as char);
        out.push(B64_ALPHABET[((triple >> 6) & 63) as usize] as char);
    }
    out
}

pub fn base64url_decode(s: &str) -> Option<Vec<u8>> {
    let mut padded = s.replace('-', "+").replace('_', "/");
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let mut out: Vec<u8> = Vec::with_capacity(padded.len() * 3 / 4);
    let bytes = padded.as_bytes();
    let mut i = 0;
    while i + 4 <= bytes.len() {
        let mut v: [u32; 4] = [0; 4];
        for k in 0..4 {
            let c = bytes[i + k];
            v[k] = match c {
                b'A'..=b'Z' => (c - b'A') as u32,
                b'a'..=b'z' => (c - b'a' + 26) as u32,
                b'0'..=b'9' => (c - b'0' + 52) as u32,
                b'+' => 62,
                b'/' => 63,
                b'=' => 0,
                _ => return None,
            };
        }
        let triple = (v[0] << 18) | (v[1] << 12) | (v[2] << 6) | v[3];
        let count = if bytes[i + 3] == b'=' {
            if bytes[i + 2] == b'=' { 1 } else { 2 }
        } else {
            3
        };
        out.push(((triple >> 16) & 0xff) as u8);
        if count >= 2 {
            out.push(((triple >> 8) & 0xff) as u8);
        }
        if count >= 3 {
            out.push((triple & 0xff) as u8);
        }
        i += 4;
    }
    Some(out)
}

// -------------------------------------------------------------
// Filename encoding (spec §6)
// -------------------------------------------------------------

pub fn sortable_hlc(hlc: &HLC) -> String {
    let unsigned = hlc.node_id as u32;
    format!(
        "{:016}-{:08}-{:010}",
        hlc.physical_time, hlc.logical_count, unsigned
    )
}

pub fn filename_for_job(job: &Job) -> String {
    format!(
        "{}-{}-{}",
        sortable_hlc(&job.submitted_at),
        job.stream_id.0,
        job.id.0
    )
}

// -------------------------------------------------------------
// JSON encoding (spec §6)
//
// We assemble a serde_json::Map manually and serialise with sorted
// keys (alphabetical) to match Swift's JSONEncoder.sortedKeys.
// -------------------------------------------------------------

fn hlc_value(hlc: &HLC) -> Value {
    let mut m = Map::new();
    m.insert(
        "physical_time".into(),
        Value::Number(serde_json::Number::from(hlc.physical_time)),
    );
    m.insert(
        "logical_count".into(),
        Value::Number(serde_json::Number::from(hlc.logical_count as i64)),
    );
    let unsigned = hlc.node_id as u32;
    m.insert(
        "node_id".into(),
        Value::Number(serde_json::Number::from(unsigned as u64)),
    );
    sort_map_alpha(Value::Object(m))
}

/// Recursively sort all object keys alphabetically.
fn sort_map_alpha(v: Value) -> Value {
    match v {
        Value::Object(m) => {
            let mut entries: Vec<(String, Value)> = m.into_iter()
                .map(|(k, v)| (k, sort_map_alpha(v))).collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            let mut out = Map::new();
            for (k, v) in entries { out.insert(k, v); }
            Value::Object(out)
        }
        Value::Array(arr) => Value::Array(
            arr.into_iter().map(sort_map_alpha).collect()),
        other => other,
    }
}

pub fn encode_job(job: &Job) -> Vec<u8> {
    let mut m = Map::new();
    m.insert("id".into(), Value::String(job.id.0.clone()));
    m.insert("stream_id".into(), Value::String(job.stream_id.0.clone()));
    m.insert("submitted_at".into(), hlc_value(&job.submitted_at));
    m.insert("priority".into(),
        Value::Number(serde_json::Number::from(job.priority as i64)));
    m.insert("payload".into(), Value::String(base64url_encode(&job.payload)));
    m.insert("extensions".into(),
        sort_map_alpha(Value::Object(job.extensions.clone())));
    let sorted = sort_map_alpha(Value::Object(m));
    serde_json::to_vec(&sorted).expect("encode")
}

pub fn encode_signal(sig: &SignalFile) -> Vec<u8> {
    let mut m = Map::new();
    m.insert("job_id".into(), Value::String(sig.job_id.0.clone()));
    m.insert("status".into(), Value::String(sig.status.raw().to_string()));
    let arts: Vec<Value> = sig.artifacts.iter().map(|a| {
        let mut am = Map::new();
        am.insert("type".into(), Value::String(a.type_tag().to_string()));
        am.insert("value".into(), Value::String(a.value().to_string()));
        Value::Object(am)
    }).collect();
    m.insert("artifacts".into(), Value::Array(arts));
    m.insert("completed_at".into(), hlc_value(&sig.completed_at));
    let sorted = sort_map_alpha(Value::Object(m));
    serde_json::to_vec(&sorted).expect("encode")
}

pub fn decode_job(bytes: &[u8]) -> Result<Job, serde_json::Error> {
    let v: Value = serde_json::from_slice(bytes)?;
    let obj = v.as_object().expect("object");
    let id = JobId(obj["id"].as_str().unwrap().to_string());
    let stream_id = StreamId(obj["stream_id"].as_str().unwrap().to_string());
    let sa = obj["submitted_at"].as_object().unwrap();
    let unsigned = sa["node_id"].as_u64().unwrap() as u32;
    let signed = unsigned as i32;
    let hlc = HLC {
        physical_time: sa["physical_time"].as_i64().unwrap(),
        logical_count: sa["logical_count"].as_i64().unwrap() as i32,
        node_id: signed,
    };
    let priority = obj["priority"].as_i64().unwrap() as i32;
    let payload = base64url_decode(obj["payload"].as_str().unwrap())
        .unwrap_or_default();
    let extensions = obj["extensions"].as_object().cloned().unwrap_or_default();
    Ok(Job { id, stream_id, submitted_at: hlc, priority,
             payload, extensions })
}
