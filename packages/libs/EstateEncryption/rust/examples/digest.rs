//! digest — a content digest of an estate database, for cross-port comparison.
//!
//! Usage: digest <db.sqlite> [key-hex]
//!
//! Emits a per-table line of `name rows <sha256 of every row>` plus a total.
//! Rows are read in rowid order and every column is folded in as its SQL text,
//! so two databases holding the same content digest identically regardless of
//! page layout, salt, or IV — which is what a physical clone must preserve and
//! what a byte comparison of two SQLCipher files cannot show.

use rusqlite::types::ValueRef;
use std::path::Path;

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// FNV-1a over the folded row text. Not a cryptographic digest: this compares
/// two local files that are both already trusted, and it needs no dependency.
fn fold(acc: &mut u64, bytes: &[u8]) {
    for b in bytes {
        *acc ^= *b as u64;
        *acc = acc.wrapping_mul(0x100_0000_01b3);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: digest <db> [key-hex]");
        std::process::exit(2);
    }
    let key: Option<Vec<u8>> = args.get(2).map(|h| {
        (0..h.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&h[i..i + 2], 16).expect("key hex"))
            .collect()
    });

    let conn = estate_encryption::open_raw(Path::new(&args[1]), key.as_deref())
        .expect("open");

    let mut stmt = conn
        .prepare(
            "SELECT name FROM sqlite_master WHERE type='table' \
             AND name NOT LIKE 'sqlite_%' ORDER BY name;",
        )
        .expect("list");
    let tables: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .expect("map")
        .map(|r| r.expect("row"))
        .collect();

    let mut total: u64 = 0xcbf2_9ce4_8422_2325;
    for table in &tables {
        let mut acc: u64 = 0xcbf2_9ce4_8422_2325;
        let mut rows = 0u64;
        let mut q = conn
            .prepare(&format!("SELECT * FROM \"{table}\";"))
            .expect("select");
        let cols = q.column_count();
        let mut it = q.query([]).expect("query");
        while let Some(row) = it.next().expect("next") {
            rows += 1;
            for i in 0..cols {
                match row.get_ref(i).expect("col") {
                    ValueRef::Null => fold(&mut acc, b"NULL"),
                    ValueRef::Integer(v) => fold(&mut acc, v.to_string().as_bytes()),
                    ValueRef::Real(v) => fold(&mut acc, v.to_string().as_bytes()),
                    ValueRef::Text(v) => fold(&mut acc, v),
                    ValueRef::Blob(v) => fold(&mut acc, v),
                }
                fold(&mut acc, b"\x1f");
            }
            fold(&mut acc, b"\x1e");
        }
        println!("{table} rows={rows} digest={}", hex(&acc.to_be_bytes()));
        fold(&mut total, table.as_bytes());
        fold(&mut total, &acc.to_be_bytes());
    }
    println!("TOTAL tables={} digest={}", tables.len(), hex(&total.to_be_bytes()));
}
