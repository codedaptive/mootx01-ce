//! VectorPayload — typed vector envelope.
//!
//! Parallel to Swift `VectorPayload`. The kind tag selects the
//! interpretation of the raw bytes:
//!
//! - Binary (0): 32-byte Engram wire form — 4 × u64 LE. Bit 0 is the LSB
//!   of the first block, matching the Engram encoding documented in the
//!   retrieval algorithms reference §0.
//! - Float32 (1): `dim` × f32 LE, 4 bytes per element.
//! - Int8 (2): `dim` × i8, one byte per element, scaled by `scale`.
//!   The quantization policy (symmetric vs asymmetric, per-vector vs
//!   per-dim scale) has NOT been ratified. `VectorStore::add_payload` and
//!   `add_payloads` REJECT Int8 writes fail-closed with
//!   `VectorKitError::Int8QuantizationPolicyUndefined` until a policy is
//!   ratified. The variant is preserved so the API does not change when
//!   the policy is eventually ratified. See VECTORKIT_SPEC §I-4a and arch
//!   spec §10.3.
//!
//! The binary payload is exactly the Engram wire form so that
//! `VectorPayload { kind: VectorKind::Binary, .. }` is zero-meaning-loss
//! inter-convertible with the existing Engram path.

use engram_lib::Engram;
use crate::error::VectorKitError;

/// Wire-level tag stored in the `kind` INTEGER column of `vectors`.
///
/// Values are stable — never renumber or remove a variant.
#[repr(i64)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum VectorKind {
    /// 32-byte Engram wire form. 4 × u64 LE.
    Binary = 0,
    /// `dim` × f32 LE.
    Float32 = 1,
    /// `dim` × i8, scaled by an optional scale factor. The quantization
    /// policy has not been ratified; `VectorStore` rejects Int8 writes
    /// fail-closed. The variant is preserved for a future policy
    /// ratification. See VECTORKIT_SPEC §I-4a and arch spec §10.3.
    Int8 = 2,
}

impl VectorKind {
    /// Decode from the raw integer stored in the `kind` column.
    /// Returns `None` for unrecognised values (forward compatibility).
    pub fn from_raw(v: i64) -> Option<Self> {
        match v {
            0 => Some(Self::Binary),
            1 => Some(Self::Float32),
            2 => Some(Self::Int8),
            _ => None,
        }
    }

    /// The stable raw integer for the `kind` column.
    pub fn raw(self) -> i64 {
        self as i64
    }
}

/// Typed vector envelope. Stores raw bytes plus metadata needed to
/// decode them. The `scale` field is only meaningful for Int8 payloads
/// (applied during dequantisation: `f32_val = i8_val × scale`).
#[derive(Debug, Clone, PartialEq)]
pub struct VectorPayload {
    pub kind: VectorKind,
    /// Number of logical elements (bits for Binary, floats for Float32,
    /// quantised integers for Int8).
    pub dim: u32,
    /// Raw byte representation. Length must agree with `kind` and `dim`.
    pub bytes: Vec<u8>,
    /// Dequantisation scale for Int8; `None` for other kinds.
    pub scale: Option<f32>,
}

impl VectorPayload {
    /// Construct from a 256-bit `Engram`. The result is an exact
    /// round-trip: `from_engram(e).as_engram()` returns `e`.
    pub fn from_engram(engram: &Engram) -> Self {
        // wire_bytes() returns 4 × u64 in little-endian byte order — the
        // canonical Engram wire form.  Binary payloads ARE this wire form.
        let bytes = engram.wire_bytes().to_vec();
        VectorPayload {
            kind: VectorKind::Binary,
            dim: 256,
            bytes,
            scale: None,
        }
    }

    /// Decode a Binary payload back to an `Engram`. Fails if the kind is
    /// not Binary or the byte count is not exactly 32.
    pub fn as_engram(&self) -> Result<Engram, VectorKitError> {
        if self.kind != VectorKind::Binary {
            return Err(VectorKitError::InvalidPayload(format!(
                "expected Binary payload, got {:?}",
                self.kind
            )));
        }
        if self.bytes.len() != 32 {
            return Err(VectorKitError::InvalidPayload(format!(
                "Binary payload must be 32 bytes, got {}",
                self.bytes.len()
            )));
        }
        Engram::from_wire_bytes(&self.bytes)
            .map_err(|e| VectorKitError::DecodingFailure(format!("engram decode: {e}")))
    }

    /// Construct a Float32 payload from a slice of f32 values.
    /// Bytes are stored as `dim` × f32 LE.
    pub fn from_f32(values: &[f32]) -> Self {
        let bytes: Vec<u8> = values
            .iter()
            .flat_map(|v| v.to_le_bytes())
            .collect();
        VectorPayload {
            kind: VectorKind::Float32,
            dim: values.len() as u32,
            bytes,
            scale: None,
        }
    }

    /// Decode a Float32 payload to a `Vec<f32>`.
    pub fn as_f32_vec(&self) -> Result<Vec<f32>, VectorKitError> {
        if self.kind != VectorKind::Float32 {
            return Err(VectorKitError::InvalidPayload(format!(
                "expected Float32 payload, got {:?}",
                self.kind
            )));
        }
        if self.bytes.len() % 4 != 0 {
            return Err(VectorKitError::DecodingFailure(format!(
                "Float32 payload byte count {} is not a multiple of 4",
                self.bytes.len()
            )));
        }
        Ok(self
            .bytes
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use engram_lib::Engram;

    #[test]
    fn from_engram_round_trips() {
        let e = Engram::new(0xCAFE_BABE_DEAD_BEEF, 0x0123, 0xFFFF, 0xABCD);
        let payload = VectorPayload::from_engram(&e);
        assert_eq!(payload.kind, VectorKind::Binary);
        assert_eq!(payload.dim, 256);
        assert_eq!(payload.bytes.len(), 32);
        let decoded = payload.as_engram().unwrap();
        assert_eq!(decoded, e);
    }

    #[test]
    fn from_f32_round_trips() {
        let vals = vec![1.0_f32, 2.0, 3.0, -1.5];
        let payload = VectorPayload::from_f32(&vals);
        assert_eq!(payload.kind, VectorKind::Float32);
        assert_eq!(payload.dim, 4);
        let decoded = payload.as_f32_vec().unwrap();
        assert_eq!(decoded, vals);
    }

    #[test]
    fn vector_kind_raw_round_trips() {
        for (k, v) in [(VectorKind::Binary, 0), (VectorKind::Float32, 1), (VectorKind::Int8, 2)] {
            assert_eq!(k.raw(), v);
            assert_eq!(VectorKind::from_raw(v), Some(k));
        }
        assert_eq!(VectorKind::from_raw(99), None);
    }

    #[test]
    fn as_engram_rejects_float32_payload() {
        let payload = VectorPayload::from_f32(&[1.0, 2.0]);
        assert!(payload.as_engram().is_err());
    }
}
