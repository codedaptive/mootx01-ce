use std::io::{self, Read, Write};

use fact_extraction_kit::FactExtractionRequest;
use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 2;
pub const MAXIMUM_FRAME_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum NuExtractArchitecture {
    /// NuExtract 1.5 tiny, based on Qwen2.5 0.5B.
    Qwen2,
    /// NuExtract 1.5, based on Phi-3.5 mini.
    Phi3,
}

impl NuExtractArchitecture {
    pub fn argument(self) -> &'static str {
        match self {
            Self::Qwen2 => "qwen2",
            Self::Phi3 => "phi3",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerRequest {
    pub protocol_version: u32,
    pub request_id: u64,
    pub extraction: FactExtractionRequest,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerResponse {
    pub protocol_version: u32,
    pub request_id: u64,
    pub result: Option<fact_extraction_kit::FactExtractionResponse>,
    pub error: Option<String>,
}

impl WorkerResponse {
    pub fn success(request_id: u64, result: fact_extraction_kit::FactExtractionResponse) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            result: Some(result),
            error: None,
        }
    }

    pub fn failure(request_id: u64, error: impl Into<String>) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            result: None,
            error: Some(error.into()),
        }
    }
}

/// Read one big-endian length-prefixed JSON value. A fixed frame ceiling makes
/// corrupted or hostile worker output fail closed before allocation.
pub fn read_frame<T: for<'de> Deserialize<'de>>(reader: &mut impl Read) -> Result<T, String> {
    let mut length = [0_u8; 4];
    reader
        .read_exact(&mut length)
        .map_err(|error| format!("read frame length: {error}"))?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > MAXIMUM_FRAME_BYTES {
        return Err(format!("invalid frame length {length}"));
    }
    let mut bytes = vec![0_u8; length];
    reader
        .read_exact(&mut bytes)
        .map_err(|error| format!("read frame body: {error}"))?;
    serde_json::from_slice(&bytes).map_err(|error| format!("decode frame JSON: {error}"))
}

/// Worker-side variant: a clean EOF before the next length prefix means the
/// host closed stdin and the resident process should release its model.
pub fn read_frame_or_eof<T: for<'de> Deserialize<'de>>(
    reader: &mut impl Read,
) -> Result<Option<T>, String> {
    let mut length = [0_u8; 4];
    match reader.read(&mut length[..1]) {
        Ok(0) => return Ok(None),
        Ok(1) => {}
        Ok(_) => unreachable!("one-byte read returned more than one byte"),
        Err(error) => return Err(format!("read frame length: {error}")),
    }
    reader
        .read_exact(&mut length[1..])
        .map_err(|error| format!("read frame length: {error}"))?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > MAXIMUM_FRAME_BYTES {
        return Err(format!("invalid frame length {length}"));
    }
    let mut bytes = vec![0_u8; length];
    reader
        .read_exact(&mut bytes)
        .map_err(|error| format!("read frame body: {error}"))?;
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|error| format!("decode frame JSON: {error}"))
}

pub fn write_frame<T: Serialize>(writer: &mut impl Write, value: &T) -> Result<(), String> {
    let bytes = serde_json::to_vec(value).map_err(|error| format!("encode frame JSON: {error}"))?;
    if bytes.is_empty() || bytes.len() > MAXIMUM_FRAME_BYTES {
        return Err(format!("invalid encoded frame length {}", bytes.len()));
    }
    let length = u32::try_from(bytes.len())
        .map_err(|_| format!("encoded frame is too large: {}", bytes.len()))?;
    writer
        .write_all(&length.to_be_bytes())
        .and_then(|_| writer.write_all(&bytes))
        .and_then(|_| writer.flush())
        .map_err(|error: io::Error| format!("write frame: {error}"))
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    #[test]
    fn frame_round_trip_does_not_treat_payload_text_as_framing() {
        let request = WorkerRequest {
            protocol_version: PROTOCOL_VERSION,
            request_id: 17,
            extraction: FactExtractionRequest {
                source_id: "drawer".into(),
                source_digest: "digest".into(),
                source_text: "line one\n{\"pretend\":\"frame\"}\0line two".into(),
                eligible_source_spans: vec![],
                maximum_facts: 4,
            },
        };
        let mut bytes = Vec::new();
        write_frame(&mut bytes, &request).unwrap();
        let decoded: WorkerRequest = read_frame(&mut Cursor::new(bytes)).unwrap();
        assert_eq!(decoded, request);
    }

    #[test]
    fn oversized_frame_is_rejected_before_body_allocation() {
        let mut bytes = Cursor::new(((MAXIMUM_FRAME_BYTES + 1) as u32).to_be_bytes());
        assert!(read_frame::<WorkerRequest>(&mut bytes).is_err());
    }
}
