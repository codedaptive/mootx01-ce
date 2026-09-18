//! EngramLib Rust integration tests. Uses substrate primitives
//! (`Engram::new`, `Engram::ZERO`) directly -- EngramLib does not
//! wrap them, so tests reach for substrate the way every caller
//! should.

use engram_lib::{Engram, EngramLib, Match};

/// Test-local convenience. Saves the `Engram::` prefix in the
/// dense fixture lines below; not exported from the crate.
fn e(b0: u64, b1: u64, b2: u64, b3: u64) -> Engram {
    Engram::new(b0, b1, b2, b3)
}

#[test]
fn distance_identical() {
    let a = e(0xDEAD, 0xBEEF, 0xCAFE, 0xBABE);
    assert_eq!(EngramLib::distance(&a, &a), 0);
}

#[test]
fn distance_inverse() {
    let a = Engram::ZERO;
    let b = e(u64::MAX, u64::MAX, u64::MAX, u64::MAX);
    assert_eq!(EngramLib::distance(&a, &b), 256);
}

#[test]
fn distance_known() {
    let a = e(0, 0, 0, 0);
    let b = e(0b1011, 0, 0, 0);
    assert_eq!(EngramLib::distance(&a, &b), 3);
}

#[test]
fn distances_empty() {
    let probe = Engram::ZERO;
    assert!(EngramLib::distances(&probe, &[]).is_empty());
}

#[test]
fn distances_batch_matches_pair() {
    let probe = e(0xAAAA_AAAA, 0, 0, 0);
    let estate: Vec<Engram> = (0..10u64)
        .map(|i| e(i.wrapping_mul(0xDEAD), i, 0, 0))
        .collect();
    let batch = EngramLib::distances(&probe, &estate);
    for i in 0..estate.len() {
        assert_eq!(batch[i], EngramLib::distance(&probe, &estate[i]));
    }
}

#[test]
fn find_nearest_empty() {
    let probe = Engram::ZERO;
    assert!(EngramLib::find_nearest(&probe, &[], 5).is_empty());
}

#[test]
fn find_nearest_k_zero() {
    let probe = Engram::ZERO;
    let estate = vec![e(1, 0, 0, 0)];
    assert!(EngramLib::find_nearest(&probe, &estate, 0).is_empty());
}

#[test]
fn find_nearest_k_greater_than_n() {
    let probe = Engram::ZERO;
    let estate = vec![e(1, 0, 0, 0), e(3, 0, 0, 0)];
    let r = EngramLib::find_nearest(&probe, &estate, 10);
    assert_eq!(r.len(), 2);
}

#[test]
fn find_nearest_ordering() {
    let probe = Engram::ZERO;
    let estate = vec![
        e(0b1111, 0, 0, 0),
        e(0b1,    0, 0, 0),
        e(0b111,  0, 0, 0),
        e(0b11,   0, 0, 0),
    ];
    let r = EngramLib::find_nearest(&probe, &estate, 3);
    assert_eq!(r.iter().map(|m| m.index).collect::<Vec<_>>(), vec![1, 3, 2]);
    assert_eq!(r.iter().map(|m| m.distance).collect::<Vec<_>>(), vec![1, 2, 3]);
}

#[test]
fn find_nearest_tie_break() {
    let probe = Engram::ZERO;
    let estate = vec![
        e(0b1,   0, 0, 0),
        e(0b10,  0, 0, 0),
        e(0b100, 0, 0, 0),
    ];
    let r = EngramLib::find_nearest(&probe, &estate, 3);
    assert_eq!(r.iter().map(|m| m.index).collect::<Vec<_>>(), vec![0, 1, 2]);
}

#[test]
fn find_nearest_one() {
    let probe = Engram::ZERO;
    let estate = vec![e(0b111, 0, 0, 0), e(0b1, 0, 0, 0)];
    let m = EngramLib::find_nearest_one(&probe, &estate).unwrap();
    assert_eq!(m.index, 1);
    assert_eq!(m.distance, 1);
}

#[test]
fn find_nearest_one_empty() {
    assert!(EngramLib::find_nearest_one(&Engram::ZERO, &[]).is_none());
}

#[test]
fn find_within() {
    let probe = Engram::ZERO;
    let estate = vec![
        e(0b1,    0, 0, 0),
        e(0b1111, 0, 0, 0),
        e(0b11,   0, 0, 0),
    ];
    let r = EngramLib::find_within(&probe, &estate, 2);
    assert_eq!(r.iter().map(|m| m.index).collect::<Vec<_>>(), vec![0, 2]);
    assert_eq!(r.iter().map(|m| m.distance).collect::<Vec<_>>(), vec![1, 2]);
}

#[test]
fn find_within_empty() {
    assert!(EngramLib::find_within(&Engram::ZERO, &[], 10).is_empty());
}

#[test]
fn union_empty() {
    assert_eq!(EngramLib::union(&[]), Engram::ZERO);
}

#[test]
fn union_two() {
    let a = e(0b1010, 0, 0, 0);
    let b = e(0b0101, 0, 0, 0);
    assert_eq!(EngramLib::union_pair(&a, &b).block0, 0b1111);
}

#[test]
fn union_many() {
    let fps = vec![
        e(0b0001, 0, 0, 0),
        e(0b0010, 0, 0, 0),
        e(0b0100, 0, 0, 0),
        e(0b1000, 0, 0, 0),
    ];
    assert_eq!(EngramLib::union(&fps).block0, 0b1111);
}

#[test]
fn session_matches_stateless() {
    let probe = e(0xDEAD_BEEF, 0, 0, 0);
    let estate: Vec<Engram> = (0..100u64)
        .map(|i| e(i.wrapping_mul(0xABCD), i, 0, 0))
        .collect();
    let stateless = EngramLib::find_nearest(&probe, &estate, 10);
    let session = EngramLib::session();
    let stateful = session.find_nearest(&probe, &estate, 10);
    assert_eq!(stateless, stateful);
}

#[test]
fn match_ordering() {
    let m1 = Match { index: 5, distance: 3 };
    let m2 = Match { index: 1, distance: 3 };
    let m3 = Match { index: 0, distance: 2 };
    assert!(m3 < m2);
    assert!(m2 < m1);
    let mut v = vec![m1, m2, m3];
    v.sort();
    assert_eq!(v.iter().map(|m| m.index).collect::<Vec<_>>(), vec![0, 1, 5]);
}


// ── Chest placement key (ADR-026), vectors shared with the Swift port ──────

use engram_lib::chest_placement;

#[test]
fn morton_key_vectors() {
    let fp = e(0x0123456789ABCDEF, 0xFEDCBA9876543210, 0x0F0F0F0F0F0F0F0F, 0xAAAAAAAAAAAAAAAA);
    assert_eq!(chest_placement::key(&fp).words, [0x0153494B6173682F, 0xC097888FA0B6F9BE, 0xFBACB3B49B8D9791, 0x3F2937711F490711,
                                                 0x15BB05FB15FA01FE, 0x11FE01BE11BE10FE, 0x88DC989C889C99D8, 0x89D8D9D8C9D989C9]);
    assert_eq!(chest_placement::key(&e(0, 0, 0, 0)).words, [0u64; 8]);
    assert_eq!(chest_placement::key(&e(u64::MAX, u64::MAX, u64::MAX, u64::MAX)).words, [u64::MAX; 8]);
}

#[test]
fn morton_key_single_bit_and_permutation_bijection() {
    // Fingerprint bit 0 → key bit 0 (ordering A) and key bit 2j+1 with permutation(j) == 0: j = 55, word 1 bit 16.
    let one = e(1 << 63, 0, 0, 0);
    assert_eq!(chest_placement::key(&one).words, [0x8000000000000000, 0x0000000000010000, 0, 0, 0, 0, 0, 0]);
    assert_eq!(chest_placement::permutation(55), 0);
    let mut seen = [false; 256];
    for i in 0..256 { seen[chest_placement::permutation(i)] = true; }
    assert!(seen.iter().all(|s| *s), "the permutation is a bijection on 0..256");
}

#[test]
fn morton_key_hex_round_trips_and_orders_like_the_key() {
    use engram_lib::morton_key::MortonKey;
    let key = MortonKey { words: [0x0153494B6173682F, 0xC097888FA0B6F9BE, 0xFBACB3B49B8D9791, 0x3F2937711F490711,
                                  0x15BB05FB15FA01FE, 0x11FE01BE11BE10FE, 0x88DC989C889C99D8, 0x89D8D9D8C9D989C9] };
    let hex = key.hex();
    assert_eq!(hex.len(), 128);
    assert!(hex.starts_with("0153494b6173682fc097888fa0b6f9be"));
    assert_eq!(MortonKey::from_hex(&hex), Some(key));
    assert_eq!(MortonKey::from_hex(&hex.to_uppercase()), Some(key));
    assert_eq!(MortonKey::from_hex(&hex[..127]), None);
    assert_eq!(MortonKey::from_hex(&"g".repeat(128)), None);
    let zero = MortonKey { words: [0; 8] };
    assert_eq!(zero.hex(), "0".repeat(128));
    assert!(zero.hex() < hex && zero < key);
}

#[test]
fn deal_and_range_index() {
    let keys: Vec<u32> = (0..10).collect();
    let ranges = chest_placement::deal(&keys, 4);
    let shape: Vec<(u32, u32, usize)> = ranges.iter().map(|r| (r.low, r.high, r.count)).collect();
    assert_eq!(shape, vec![(0, 3, 4), (4, 7, 4), (8, 9, 2)]);
    assert_eq!(chest_placement::range_index(&5, &ranges), Some(1));
    assert_eq!(chest_placement::range_index(&9, &ranges), Some(2));
    assert_eq!(chest_placement::range_index(&11, &ranges), None);
    assert!(chest_placement::deal::<u32>(&[], 4).is_empty());
    assert_eq!((chest_placement::CAPACITY, chest_placement::FILL), (500, 250));
}
