// build.rs — subsystem 6 (source-CRC drift), stamp half.
//
// At compile time, walk the Rust source of the substrate libs this app links,
// CRC32 the concatenated bytes (sorted by absolute path for determinism), and
// bake the result in as SUBSTRATE_SRC_CRC. At runtime the app recomputes the
// same CRC over the same files; a mismatch means the source drifted since this
// binary was built. The runtime walk in src/main.rs MUST mirror this one exactly
// (same lib set, same recursion, same sort, same byte concatenation).
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

const LIBS: [&str; 4] = ["SubstrateTypes", "SubstrateKernel", "SubstrateML", "SubstrateLib"];

fn collect_rs(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect_rs(&p, out);
        } else if p.extension().map_or(false, |x| x == "rs") {
            out.push(p);
        }
    }
}

// CRC-32/ISO-HDLC — identical parameters to harness::CRC32 (poly 0xEDB88320,
// init 0xFFFFFFFF, reflected, final XOR 0xFFFFFFFF).
fn crc32(bytes: &[u8]) -> u32 {
    let mut s: u32 = 0xFFFF_FFFF;
    for &b in bytes {
        s ^= b as u32;
        for _ in 0..8 {
            s = if s & 1 == 1 { 0xEDB8_8320 ^ (s >> 1) } else { s >> 1 };
        }
    }
    s ^ 0xFFFF_FFFF
}

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let mut files = Vec::new();
    for lib in LIBS {
        let src = manifest.join(format!("../../../../../packages/libs/{lib}/rust/src"));
        if let Ok(canon) = src.canonicalize() {
            collect_rs(&canon, &mut files);
        }
    }
    files.sort();
    let mut data = Vec::new();
    for f in &files {
        if let Ok(b) = fs::read(f) {
            data.extend_from_slice(&b);
        }
        println!("cargo:rerun-if-changed={}", f.display());
    }
    println!("cargo:rustc-env=SUBSTRATE_SRC_CRC={:08x}", crc32(&data));
    println!("cargo:rustc-env=SUBSTRATE_SRC_FILES={}", files.len());
}
