// Pinned vectors shared with ContentFingerprintTests.swift (ADR-026).
use substrate_ml::content_fingerprint::{fingerprint, fingerprint_of_shingles};
use substrate_ml::shingle_similarity::shingles;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hamming::{distance, ALL_BLOCKS};

const FOX: &str = "The quick brown fox jumps over the lazy dog";

#[test]
fn pinned_vectors() {
    let f = fingerprint(FOX);
    assert_eq!(f, Fingerprint256::new(0x2B60F941D15CAEE5, 0x1C47031194216C3A, 0x0DD73D2100654F5F, 0xB3CACB0CD2AEEA7C));
    assert_eq!(fingerprint("ab"), Fingerprint256::new(0x32F20CC2F25D2AF7, 0x7F4A8CCBA9F51C9E, 0x3E4E64B3921FC98D, 0x7DC1B4B9FF22AC34));
    assert_eq!(fingerprint(""), Fingerprint256::ZERO);
    assert_eq!(fingerprint("THE QUICK brown fox jumps over the lazy DOG"), f, "case folds before shingling");
    assert_eq!(fingerprint_of_shingles(&shingles(FOX)), f, "the set form is the same math");
}

#[test]
fn distance_tracks_overlap() {
    let f = fingerprint(FOX);
    let near = fingerprint("The quick brown fox jumped over the lazy dogs");
    let far = fingerprint("Quarterly revenue rose nine percent on services");
    assert_eq!(distance(&f, &near, ALL_BLOCKS), 30);
    assert_eq!(distance(&f, &far, ALL_BLOCKS), 92);
}
