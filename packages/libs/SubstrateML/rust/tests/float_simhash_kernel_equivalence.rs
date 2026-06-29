//! Step-1 (M4) equivalence: `substrate_kernel`'s `float_simhash_project`
//! (scalar reference) reproduces `substrate_ml::float_simhash::project`
//! bit-for-bit, via planes materialized by `float_simhash::planes`. This is the
//! bit-identity gate between the two generate-then-apply paths: both
//! `substrate_ml::float_simhash::project` and `substrate_kernel`'s
//! `float_simhash_project` materialize planes then project. Mirror of Swift
//! `FloatSimHashKernelEquivalenceTests`.

use substrate_kernel::kernel::{ScalarKernel, SubstrateKernel};
use substrate_ml::float_simhash;
use substrate_types::Fingerprint256;

#[test]
fn scalar_kernel_matches_oracle() {
    let kernel = ScalarKernel;
    let seeds: [u64; 4] = [0, 1, 0x4644_435F_5631_5F50, 0xDEAD_BEEF_CAFE_F00D];
    let dims = [1usize, 8, 256, 384, 768];
    for &seed in &seeds {
        for &dim in &dims {
            // Sign-mixed vector so per-hyperplane sums land near zero — the
            // regime where a reordered reduction would flip a bit.
            let v: Vec<f32> = (0..dim).map(|i| ((i * 31 % 13) as f32) - 6.0).collect();
            let expected = float_simhash::project(&v, seed);
            let planes = float_simhash::planes(seed, dim);
            let got = kernel.float_simhash_project(&v, &planes);
            assert_eq!(got, expected, "mismatch at seed={seed} dim={dim}");
        }
    }
}

#[test]
fn empty_vector_projects_to_zero() {
    let kernel = ScalarKernel;
    let planes = float_simhash::planes(1, 0);
    let got = kernel.float_simhash_project(&[], &planes);
    assert_eq!(got, float_simhash::project(&[], 1));
    assert_eq!(got, Fingerprint256::ZERO);
}
