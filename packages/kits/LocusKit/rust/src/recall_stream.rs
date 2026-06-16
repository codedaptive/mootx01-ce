//! Paged cursor over recall results. Ports `RecallStream.swift`.
//!
//! Swift's `RecallStream` is an `AsyncSequence`; the Rust port is a
//! synchronous paged cursor because the persistence-kit Rust trait is sync.
//! The page-boundary contract (`page_index`, `is_last`, hydration
//! semantics) is identical to the Swift contract so LP-0 vectors pass
//! identically across both legs.
//!
//! ## Hydration
//!
//! `HydrationLevel` is applied at page-emission time (on each
//! `next_page()` call). `BitmapOnly` strips the `content` field so
//! callers receive only the bitmap / metadata surface (spec § 7.3
//! lightest tier); `Structured` and `Full` return rows unchanged at
//! this tier — `Full` becomes distinct from `Structured` only when the
//! blob tier ships in a later mission.
//!
//! ## Empty corpus
//!
//! An empty row set emits exactly one final page with `rows.is_empty()`
//! and `is_last = true`. Callers iterate uniformly without
//! special-casing the zero-row corpus.
//!
//! Per spec §§ 7.8.4 / 7.3 / 7.4.

use crate::drawer::Drawer;
use crate::filter::HydrationLevel;

// MARK: - RecallPage

/// One page of recall results. `page_index` is zero-based; `is_last` is
/// true only on the final page emitted by the cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecallPage {
    /// The rows in this page, hydrated according to the stream's
    /// `HydrationLevel`.
    pub rows: Vec<Drawer>,
    /// Zero-based page index.
    pub page_index: usize,
    /// True when this is the last page in the stream.
    pub is_last: bool,
}

// MARK: - RecallStream

/// Synchronous paged cursor over recall results.
///
/// Constructed by `Estate::recall`. `page_size` is clamped to at least
/// 1 — a non-positive page size would loop forever or produce zero-row
/// pages with `is_last == false`, both of which violate spec § 7.8.4.
///
/// Call `next_page()` repeatedly until the returned `RecallPage` has
/// `is_last == true`. Calling `next_page()` after the last page returns
/// `None`.
///
/// The default page size (50) matches the Swift `RecallStream.defaultPageSize`.
pub struct RecallStream {
    rows: Vec<Drawer>,
    /// Page size, always ≥ 1.
    page_size: usize,
    hydration_level: HydrationLevel,
    /// Offset into `rows` for the next page.
    offset: usize,
    /// Zero-based page index of the next page to emit.
    page_index: usize,
    /// Set to true once a page with `is_last = true` has been emitted.
    exhausted: bool,
    /// Named internal-read failures that occurred while `Estate::recall`
    /// produced this stream. EMPTY for a genuine result (every internal read
    /// succeeded — including the genuine-empty estate, where the reads
    /// succeeded and matched no rows). NON-EMPTY only when an internal read
    /// (`live_rows`, room-fingerprints, room-drawer-read, or the bitmap
    /// evaluator) FAILED and its rows were dropped: in that case `rows` may be
    /// empty for a reason OTHER than "no matches", and this names which stage
    /// failed so a consumer can tell a FAILED recall from a GENUINE-EMPTY
    /// estate. `recall` is non-throwing per spec § 7.8.1, so this field — not
    /// an `Err` — is the channel. Mirrors Swift `RecallStream.degradedStages`.
    /// The GLK coordinator merges these into `GLKRecallResult.degraded_stages`.
    degraded_stages: Vec<String>,
}

impl RecallStream {
    /// Default rows per page when `RecallFrame.limit` is `None`. Per
    /// spec § 7.8.4 — implementation default is 50.
    pub const DEFAULT_PAGE_SIZE: usize = 50;

    /// Construct a `RecallStream` over `rows`. `page_size` is clamped
    /// to ≥ 1. `hydration_level` is applied on each `next_page()` call.
    ///
    /// Mirrors `RecallStream.init(rows:pageSize:hydrationLevel:)` in Swift.
    pub fn new(rows: Vec<Drawer>, page_size: usize, hydration_level: HydrationLevel) -> Self {
        // Clamp to at least 1 — same guard as `Swift.max(1, pageSize)`.
        let page_size = page_size.max(1);
        Self {
            rows,
            page_size,
            hydration_level,
            offset: 0,
            page_index: 0,
            exhausted: false,
            degraded_stages: Vec::new(),
        }
    }

    /// Attach named internal-read failure stages to this stream (builder
    /// style). Used by `Estate::recall` to thread a failed-read signal to the
    /// consumer without changing `new`'s signature — every existing
    /// `RecallStream::new(rows, page_size, hydration_level)` call site (incl.
    /// the in-crate tests) compiles unchanged and carries an empty
    /// `degraded_stages`.
    pub fn with_degraded_stages(mut self, stages: Vec<String>) -> Self {
        self.degraded_stages = stages;
        self
    }

    /// The named internal-read failures recorded while producing this stream.
    /// Empty for a genuine (including genuine-empty) result. See the field doc.
    pub fn degraded_stages(&self) -> &[String] {
        &self.degraded_stages
    }

    /// Emit the next page. Returns `None` when the stream is exhausted
    /// (i.e., `next_page()` has already returned a page with `is_last =
    /// true`).
    ///
    /// An empty corpus emits exactly one page: `rows = []`, `page_index
    /// = 0`, `is_last = true`. Callers iterate uniformly without
    /// special-casing the zero-row corpus.
    pub fn next_page(&mut self) -> Option<RecallPage> {
        if self.exhausted {
            return None;
        }
        let end = (self.offset + self.page_size).min(self.rows.len());
        let slice: Vec<Drawer> = self.rows[self.offset..end]
            .iter()
            .map(|d| hydrate(d, self.hydration_level))
            .collect();
        let is_last = end >= self.rows.len();
        let page = RecallPage {
            rows: slice,
            page_index: self.page_index,
            is_last,
        };
        self.offset = end;
        self.page_index += 1;
        if is_last {
            self.exhausted = true;
        }
        Some(page)
    }

    /// Convenience: drain all pages into a flat `Vec<Drawer>`. Used by
    /// the test harness and by Estate::recall callers that want all rows
    /// without paging logic.
    pub fn collect_all(mut self) -> Vec<Drawer> {
        let mut all = Vec::new();
        while let Some(page) = self.next_page() {
            all.extend(page.rows);
        }
        all
    }

    /// Drain all pages AND return the stream's named internal-read failures.
    /// The GLK RecallDirector lanes use this (rather than `collect_all`) so a
    /// FAILED locus recall surfaces its `locus.*` stage in
    /// `GLKRecallResult.degraded_stages`, distinguishable from a GENUINE-EMPTY
    /// estate (empty stages). Mirrors the Swift director reading
    /// `stream.degradedStages` after the `for await page in stream` drain.
    pub fn collect_all_with_degraded(self) -> (Vec<Drawer>, Vec<String>) {
        // Capture stages before `collect_all` consumes `self`.
        let stages = self.degraded_stages.clone();
        (self.collect_all(), stages)
    }
}

// MARK: - Private helpers

/// Apply `hydration_level` to a row. `BitmapOnly` rebuilds the `Drawer`
/// with `content = ""` while preserving every other field (notably the
/// bitmap columns). `Structured` and `Full` pass the row through unchanged.
/// Mirrors `RecallStream.AsyncIterator.hydrate(_:)` in Swift.
fn hydrate(d: &Drawer, level: HydrationLevel) -> Drawer {
    match level {
        HydrationLevel::BitmapOnly => {
            // Preserve all fields except content, which is cleared so
            // callers receive only the bitmap/metadata surface.
            let mut d2 = d.clone();
            d2.content = String::new();
            d2
        }
        // Structured and Full are identical at this tier; Full becomes
        // distinct only when the blob tier ships in a later mission.
        HydrationLevel::Structured | HydrationLevel::Full => d.clone(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::filter::HydrationLevel;

    fn make_drawer(id: &str, content: &str) -> Drawer {
        Drawer::new(
            id,
            content,
            "wing",
            "room",
            "alice",
            1_700_000_000,
            "test-v1",
        )
    }

    // --- Default page size ---

    #[test]
    fn default_page_size_is_fifty() {
        assert_eq!(RecallStream::DEFAULT_PAGE_SIZE, 50);
    }

    // --- Empty corpus ---

    #[test]
    fn empty_corpus_emits_one_final_page() {
        let mut stream = RecallStream::new(vec![], 50, HydrationLevel::Structured);
        let page = stream.next_page().expect("should emit one page");
        assert!(page.rows.is_empty());
        assert_eq!(page.page_index, 0);
        assert!(page.is_last);
        assert!(stream.next_page().is_none(), "no pages after last");
    }

    // --- Single page ---

    #[test]
    fn three_rows_one_page_when_page_size_ten() {
        let rows = vec![
            make_drawer("d1", "a"),
            make_drawer("d2", "b"),
            make_drawer("d3", "c"),
        ];
        let mut stream = RecallStream::new(rows, 10, HydrationLevel::Structured);
        let page = stream.next_page().unwrap();
        assert_eq!(page.rows.len(), 3);
        assert_eq!(page.page_index, 0);
        assert!(page.is_last);
        assert!(stream.next_page().is_none());
    }

    // --- Pagination ---

    #[test]
    fn five_rows_page_size_two_gives_three_pages() {
        let rows: Vec<_> = (1..=5)
            .map(|i| make_drawer(&format!("d{i}"), &format!("c{i}")))
            .collect();
        let mut stream = RecallStream::new(rows, 2, HydrationLevel::Structured);

        let p0 = stream.next_page().unwrap();
        assert_eq!(p0.rows.len(), 2);
        assert_eq!(p0.page_index, 0);
        assert!(!p0.is_last);

        let p1 = stream.next_page().unwrap();
        assert_eq!(p1.rows.len(), 2);
        assert_eq!(p1.page_index, 1);
        assert!(!p1.is_last);

        let p2 = stream.next_page().unwrap();
        assert_eq!(p2.rows.len(), 1);
        assert_eq!(p2.page_index, 2);
        assert!(p2.is_last);

        assert!(stream.next_page().is_none());
    }

    // --- page_size clamped to 1 ---

    #[test]
    fn zero_page_size_clamped_to_one() {
        // page_size = 0 must be clamped to 1, not produce an infinite loop.
        let rows = vec![make_drawer("d1", "x"), make_drawer("d2", "y")];
        let mut stream = RecallStream::new(rows, 0, HydrationLevel::Structured);
        let p0 = stream.next_page().unwrap();
        assert_eq!(p0.rows.len(), 1);
        assert!(!p0.is_last);
        let p1 = stream.next_page().unwrap();
        assert_eq!(p1.rows.len(), 1);
        assert!(p1.is_last);
        assert!(stream.next_page().is_none());
    }

    // --- BitmapOnly hydration ---

    #[test]
    fn bitmap_only_strips_content() {
        let mut d = make_drawer("d1", "secret content");
        d.adjective_bitmap = 0xF0; // preserve bitmap value
        let rows = vec![d.clone()];
        let mut stream = RecallStream::new(rows, 50, HydrationLevel::BitmapOnly);
        let page = stream.next_page().unwrap();
        assert_eq!(page.rows.len(), 1);
        // content cleared
        assert_eq!(page.rows[0].content, "");
        // bitmap preserved
        assert_eq!(page.rows[0].adjective_bitmap, 0xF0);
        // id preserved
        assert_eq!(page.rows[0].id, "d1");
    }

    // --- Structured hydration passes through ---

    #[test]
    fn structured_hydration_preserves_content() {
        let rows = vec![make_drawer("d1", "keep me")];
        let mut stream = RecallStream::new(rows, 50, HydrationLevel::Structured);
        let page = stream.next_page().unwrap();
        assert_eq!(page.rows[0].content, "keep me");
    }

    // --- collect_all ---

    #[test]
    fn collect_all_drains_all_rows() {
        let rows: Vec<_> = (1..=7)
            .map(|i| make_drawer(&format!("d{i}"), "x"))
            .collect();
        let stream = RecallStream::new(rows, 3, HydrationLevel::Structured);
        let all = stream.collect_all();
        assert_eq!(all.len(), 7);
    }
}
