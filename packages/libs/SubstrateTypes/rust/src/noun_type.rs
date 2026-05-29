//! Eight noun categories that a substrate row can hold, per
//! cookbook §2.5. Raw values are wire-stable and must never be
//! renumbered. Moved here from substrate-lib in Phase 6.3 of the
//! pre-ship refactor (decision 2026-05-28 §6.6).

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum NounType {
    Drawer = 0,
    Tunnel = 1,
    KGFact = 2,
    DiaryEntry = 3,
    Proposal = 4,
    Association = 5,
    LearnedReference = 6,
    AmbientSample = 7,
}
