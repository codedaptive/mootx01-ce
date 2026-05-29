// eigenvalue_centrality.rs
//
// Eigenvalue centrality on the estate graph, per cookbook § 7.2.
// Mirror of glref-swift-EigenvalueCentrality.swift.

pub struct EigenvalueCentrality;

impl EigenvalueCentrality {
    pub const DEFAULT_MAX_ITERATIONS: usize = 100;
    pub const DEFAULT_TOLERANCE: f64 = 1.0e-6;

    /// Power iteration on a sparse adjacency.
    ///
    /// `adjacency[i]` is the slice of `(neighbor_index, weight)`
    /// pairs originating at row `i`. The graph is directed;
    /// callers wanting undirected centrality should symmetrize
    /// before calling. Returns the L2-normalized principal
    /// eigenvector.
    ///
    /// Implementation detail: a small Perron shift
    /// (`x_next += SHIFT * x`) is applied each iteration. This
    /// shifts every eigenvalue by `SHIFT` without changing the
    /// eigenvectors, breaking the ±λ oscillation that bipartite
    /// graphs (e.g. a star) exhibit under raw power iteration.
    /// Choose SHIFT smaller than the smallest positive eigenvalue
    /// gap of the graphs we care about; 1.0 is conservative for
    /// the unit-weighted estate graphs we see in practice.
    pub fn compute(
        adjacency: &[Vec<(usize, f64)>],
        max_iterations: usize,
        tolerance: f64,
    ) -> Vec<f64> {
        const SHIFT: f64 = 1.0;
        let n = adjacency.len();
        if n == 0 {
            return Vec::new();
        }

        let initial = 1.0 / (n as f64).sqrt();
        let mut x = vec![initial; n];
        let mut x_next = vec![0.0; n];

        for _ in 0..max_iterations {
            for v in x_next.iter_mut() {
                *v = 0.0;
            }
            for i in 0..n {
                for &(j, w) in &adjacency[i] {
                    x_next[j] += w * x[i];
                }
            }
            // Perron shift: y = A*x + SHIFT*x. Same eigenvectors,
            // eigenvalues shifted by SHIFT, breaks ±λ oscillation.
            for i in 0..n {
                x_next[i] += SHIFT * x[i];
            }
            let mut sum_sq = 0.0;
            for v in &x_next {
                sum_sq += v * v;
            }
            let norm = sum_sq.sqrt();
            if norm < 1.0e-30 {
                return vec![initial; n];
            }
            for v in x_next.iter_mut() {
                *v /= norm;
            }

            let mut diff_sq = 0.0;
            for i in 0..n {
                let d = x_next[i] - x[i];
                diff_sq += d * d;
            }
            if diff_sq.sqrt() < tolerance {
                return x_next;
            }
            std::mem::swap(&mut x, &mut x_next);
        }
        x
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_graph_yields_empty_vector() {
        let result = EigenvalueCentrality::compute(&[], 100, 1.0e-6);
        assert!(result.is_empty());
    }

    #[test]
    fn isolated_graph_yields_uniform_centrality() {
        // No edges: norm collapses, return uniform.
        let adj: Vec<Vec<(usize, f64)>> = vec![Vec::new(); 5];
        let result = EigenvalueCentrality::compute(&adj, 100, 1.0e-6);
        let expected = 1.0 / 5.0_f64.sqrt();
        for v in &result {
            assert!((v - expected).abs() < 1e-9);
        }
    }

    #[test]
    fn star_graph_centers_on_hub() {
        // Star: node 0 is hub with edges TO four leaves; the
        // dominant eigenvector under undirected-symmetric A has
        // the hub at sqrt(1/2) and leaves at sqrt(1/8) each.
        // Build symmetric adjacency.
        let n = 5;
        let mut adj: Vec<Vec<(usize, f64)>> = vec![Vec::new(); n];
        for leaf in 1..n {
            adj[0].push((leaf, 1.0));
            adj[leaf].push((0, 1.0));
        }
        let result = EigenvalueCentrality::compute(&adj, 200, 1.0e-9);
        // Hub should be most central.
        let hub = result[0].abs();
        for leaf in 1..n {
            assert!(hub > result[leaf].abs());
        }
        // All four leaves equally central (by symmetry).
        for i in 2..n {
            assert!((result[i].abs() - result[1].abs()).abs() < 1e-6);
        }
    }

    #[test]
    fn normalized_to_unit_length() {
        // Triangle, symmetric.
        let mut adj: Vec<Vec<(usize, f64)>> = vec![Vec::new(); 3];
        adj[0].push((1, 1.0));
        adj[1].push((0, 1.0));
        adj[1].push((2, 1.0));
        adj[2].push((1, 1.0));
        adj[0].push((2, 1.0));
        adj[2].push((0, 1.0));
        let result = EigenvalueCentrality::compute(&adj, 200, 1.0e-9);
        let mut sum_sq = 0.0;
        for v in &result {
            sum_sq += v * v;
        }
        assert!((sum_sq - 1.0).abs() < 1e-6);
    }

    #[test]
    fn weight_scaling_preserves_direction() {
        // Multiplying every edge weight by c should leave the
        // normalized eigenvector unchanged.
        let mut adj: Vec<Vec<(usize, f64)>> = vec![Vec::new(); 4];
        adj[0].push((1, 1.0));
        adj[1].push((2, 1.0));
        adj[2].push((3, 1.0));
        adj[3].push((0, 1.0));
        let result_unit = EigenvalueCentrality::compute(&adj, 300, 1.0e-9);

        let mut adj_scaled = adj.clone();
        for edges in adj_scaled.iter_mut() {
            for e in edges.iter_mut() {
                e.1 *= 7.5;
            }
        }
        let result_scaled = EigenvalueCentrality::compute(&adj_scaled, 300, 1.0e-9);

        for i in 0..4 {
            assert!((result_unit[i].abs() - result_scaled[i].abs()).abs() < 1e-6);
        }
    }
}
