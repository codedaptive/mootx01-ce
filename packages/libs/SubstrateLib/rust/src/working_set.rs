// working_set.rs
//
// Memory-mapped working set per cookbook § 4.2. Mirror of
// glref-swift-WorkingSetMmap.swift.
//
// Reference implementation: portable file I/O. Production uses
// mmap on Apple/Linux and CreateFileMapping on Windows. The
// substrate operations must produce bit-identical output
// regardless of which I/O backend the platform uses.

use std::fs;
use std::path::Path;
use substrate_types::hlc::HLC;
use substrate_types::bit_tensor::ThreeDBitTensor;

#[derive(Debug, Clone)]
pub struct WorkingSetHeader {
    pub row_count: u64,
    pub field_count: u64,
    pub bits_per_field: u64,
    pub slice_byte_size: u64,
    pub last_hlc: HLC,
    pub crc32: u32,
}

impl WorkingSetHeader {
    pub const MAGIC: u64 = 0x474C4F435553574B;     // "GLOCUSWK"
    pub const VERSION: u32 = 1;
    pub const PAGE_SIZE: u32 = 4096;
    pub const HEADER_SIZE: usize = 4096;
}

#[derive(Debug)]
pub struct WorkingSet {
    pub tensor: ThreeDBitTensor,
    pub header: WorkingSetHeader,
    pub path: std::path::PathBuf,
}

impl WorkingSet {
    pub fn new(path: &Path, row_count: usize) -> Self {
        let tensor = ThreeDBitTensor::new(row_count);
        let slice_bytes = (row_count * ThreeDBitTensor::FIELD_COUNT + 7) / 8;
        let header = WorkingSetHeader {
            row_count: row_count as u64,
            field_count: ThreeDBitTensor::FIELD_COUNT as u64,
            bits_per_field: ThreeDBitTensor::BITS_PER_FIELD as u64,
            slice_byte_size: slice_bytes as u64,
            last_hlc: HLC::zero(),
            crc32: 0,
        };
        Self { tensor, header, path: path.to_path_buf() }
    }

    pub fn open_or_create(path: &Path, row_count: usize) -> std::io::Result<Self> {
        if path.exists() {
            Self::load(path)
        } else {
            Ok(Self::new(path, row_count))
        }
    }

    /// Persist to disk. Writes header + all six slices.
    pub fn flush(&mut self, hlc: HLC) -> std::io::Result<()> {
        let mut data = Vec::with_capacity(
            WorkingSetHeader::HEADER_SIZE + self.tensor.byte_size()
        );

        // Pack header (little-endian).
        let mut header_bytes = vec![0_u8; WorkingSetHeader::HEADER_SIZE];
        header_bytes[0..8].copy_from_slice(&WorkingSetHeader::MAGIC.to_le_bytes());
        header_bytes[8..12].copy_from_slice(&WorkingSetHeader::VERSION.to_le_bytes());
        header_bytes[12..16].copy_from_slice(&WorkingSetHeader::PAGE_SIZE.to_le_bytes());
        header_bytes[16..24].copy_from_slice(&(self.tensor.row_count as u64).to_le_bytes());
        header_bytes[24..32].copy_from_slice(&(ThreeDBitTensor::FIELD_COUNT as u64).to_le_bytes());
        header_bytes[32..40].copy_from_slice(&(ThreeDBitTensor::BITS_PER_FIELD as u64).to_le_bytes());
        header_bytes[40..48].copy_from_slice(&self.header.slice_byte_size.to_le_bytes());
        header_bytes[48..56].copy_from_slice(&hlc.packed().to_le_bytes());

        data.extend_from_slice(&header_bytes);
        for slice in &self.tensor.slices {
            data.extend_from_slice(slice);
        }
        fs::write(&self.path, data)
    }

    /// Load from disk, validate header, reconstruct bit-tensor.
    pub fn load(path: &Path) -> std::io::Result<Self> {
        let data = fs::read(path)?;
        if data.len() < WorkingSetHeader::HEADER_SIZE {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData, "file too small"));
        }
        let magic = u64::from_le_bytes(data[0..8].try_into().unwrap());
        if magic != WorkingSetHeader::MAGIC {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData, "bad magic"));
        }
        let row_count = u64::from_le_bytes(data[16..24].try_into().unwrap()) as usize;
        let mut ws = Self::new(path, row_count);
        let slice_bytes = ws.header.slice_byte_size as usize;
        let mut offset = WorkingSetHeader::HEADER_SIZE;
        for b in 0..ThreeDBitTensor::BITS_PER_FIELD {
            ws.tensor.slices[b] = data[offset..offset + slice_bytes].to_vec();
            offset += slice_bytes;
        }
        Ok(ws)
    }
}
