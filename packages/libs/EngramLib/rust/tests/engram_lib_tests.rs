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
