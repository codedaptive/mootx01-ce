// feature_extractors.rs
//
// Per-stream feature extractors per cookbook § 3.9. Mirror of
// glref-swift-FeatureExtractors.swift.
//
// Five streams: HealthKit, CoreLocation, EventKit, ScreenTime,
// SystemTelemetry. OS-bound capture lives in ARIA_iOS/ARIA_MacOS;
// only the substrate-side encoding (subhash composition,
// SimHash, lattice anchor selection) lives here.

use substrate_types::hlc::HLC;
use substrate_types::hyperplane::HyperplaneFamily;
use substrate_types::simhash;
use substrate_types::fingerprint256::Fingerprint256;

// MARK: - Shared types

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum StreamSourceFlag {
    HealthKit       = 0b0000_0001,
    CoreLocation    = 0b0000_0010,
    EventKit        = 0b0000_0100,
    ScreenTime      = 0b0000_1000,
    SystemTelemetry = 0b0001_0000,
    LatticeLookup   = 0b0010_0000,
}

#[derive(Debug, Clone)]
pub struct AmbientSampleRow {
    pub row_id: u128,
    pub capture_hlc: HLC,
    pub stream_source: u8,            // bitmap field p06
    pub fingerprint: Fingerprint256,
    pub lattice_udc: String,
    pub payload: Vec<u8>,
}

// FNV-1a is now a public SubstrateLib atomic (see glref-rust-fnv.rs);
// the local `fnv64` helper that used to live here was removed under
// I-25 when F5b promoted the family to public. Callers below use
// `substrate_types::fnv::hash64` directly. The bare prime `0x100000001B3`
// retained in the attendee combiner below is the FNV-1a 64-bit prime,
// used here as a custom mixing constant rather than as part of a
// string hash.

// MARK: - HealthKit

#[derive(Debug, Clone)]
pub struct HealthKitSample {
    pub quantity_type: String,
    pub value: f64,
    pub unit: String,
    pub start_date: f64,
    pub end_date: f64,
    pub source_device: String,
}

pub struct HealthKitExtractor<'a> {
    pub hyperplanes: &'a [HyperplaneFamily; 4],
}

impl<'a> HealthKitExtractor<'a> {
    pub fn extract(&self, s: &HealthKitSample, hlc: HLC, row_id: u128) -> AmbientSampleRow {
        let subhashes = [
            substrate_types::fnv::hash64(&s.quantity_type),
            (s.value * 1_000_000.0) as i64 as u64,
            (s.end_date * 1000.0) as i64 as u64,
            substrate_types::fnv::hash64(&s.source_device),
        ];
        let fp = simhash::fingerprint_from_subhashes(&subhashes, self.hyperplanes);
        let payload = encode_payload(&[
            ("type", &s.quantity_type),
            ("value", &s.value.to_string()),
            ("unit", &s.unit),
            ("src", &s.source_device),
        ]);
        AmbientSampleRow {
            row_id, capture_hlc: hlc,
            stream_source: StreamSourceFlag::HealthKit as u8,
            fingerprint: fp,
            lattice_udc: "613.71".to_string(),
            payload,
        }
    }
}

// MARK: - CoreLocation

#[derive(Debug, Clone, Copy)]
pub struct CoreLocationSample {
    pub latitude: f64,
    pub longitude: f64,
    pub altitude: f64,
    pub speed: f64,
    pub course: f64,
    pub timestamp: f64,
    pub horizontal_accuracy: f64,
}

pub struct CoreLocationExtractor<'a> {
    pub hyperplanes: &'a [HyperplaneFamily; 4],
}

impl<'a> CoreLocationExtractor<'a> {
    pub fn extract(&self, s: &CoreLocationSample, hlc: HLC, row_id: u128) -> AmbientSampleRow {
        let lat_q = (s.latitude * 1_000_000.0) as i64;
        let lon_q = (s.longitude * 1_000_000.0) as i64;
        let alt_q = s.altitude as i64;
        let geohash = quantize_geohash(s.latitude, s.longitude, 6);
        let subhashes = [
            (lat_q as u64).wrapping_mul(0x100000001B3),
            (lon_q as u64).wrapping_mul(0x100000001B3),
            alt_q as u64,
            substrate_types::fnv::hash64(&geohash),
        ];
        let fp = simhash::fingerprint_from_subhashes(&subhashes, self.hyperplanes);
        AmbientSampleRow {
            row_id, capture_hlc: hlc,
            stream_source: StreamSourceFlag::CoreLocation as u8,
            fingerprint: fp,
            lattice_udc: "914".to_string(),
            payload: Vec::new(),
        }
    }
}

fn quantize_geohash(lat: f64, lon: f64, precision: u32) -> String {
    let scale = 10_f64.powi(precision as i32);
    let lat_bucket = (lat * scale).floor() as i64;
    let lon_bucket = (lon * scale).floor() as i64;
    format!("{},{}", lat_bucket, lon_bucket)
}

// MARK: - EventKit

#[derive(Debug, Clone)]
pub struct EventKitSample {
    pub event_identifier: String,
    pub title: String,
    pub start_date: f64,
    pub end_date: f64,
    pub calendar_identifier: String,
    pub attendees: Vec<String>,
    pub location: String,
}

pub struct EventKitExtractor<'a> {
    pub hyperplanes: &'a [HyperplaneFamily; 4],
}

impl<'a> EventKitExtractor<'a> {
    pub fn extract(&self, s: &EventKitSample, hlc: HLC, row_id: u128) -> AmbientSampleRow {
        let mut att_hash: u64 = 0xCBF29CE484222325;
        let mut sorted = s.attendees.clone();
        sorted.sort();
        for a in &sorted {
            att_hash ^= substrate_types::fnv::hash64(a);
            att_hash = att_hash.wrapping_mul(0x100000001B3);
        }
        let subhashes = [
            substrate_types::fnv::hash64(&s.title),
            (s.start_date * 1000.0) as i64 as u64,
            substrate_types::fnv::hash64(&s.calendar_identifier),
            att_hash,
        ];
        let fp = simhash::fingerprint_from_subhashes(&subhashes, self.hyperplanes);
        AmbientSampleRow {
            row_id, capture_hlc: hlc,
            stream_source: StreamSourceFlag::EventKit as u8,
            fingerprint: fp,
            lattice_udc: "65.012.4".to_string(),
            payload: Vec::new(),
        }
    }
}

// MARK: - ScreenTime

#[derive(Debug, Clone)]
pub struct ScreenTimeSample {
    pub app_bundle_id: String,
    pub category_identifier: String,
    pub usage_seconds: i64,
    pub pickups: i64,
    pub notifications: i64,
    pub window_start: f64,
    pub window_end: f64,
}

pub struct ScreenTimeExtractor<'a> {
    pub hyperplanes: &'a [HyperplaneFamily; 4],
}

impl<'a> ScreenTimeExtractor<'a> {
    pub fn extract(&self, s: &ScreenTimeSample, hlc: HLC, row_id: u128) -> AmbientSampleRow {
        let subhashes = [
            substrate_types::fnv::hash64(&s.app_bundle_id),
            substrate_types::fnv::hash64(&s.category_identifier),
            s.usage_seconds as u64,
            (s.pickups as u64).wrapping_mul(0x100).wrapping_add(s.notifications as u64),
        ];
        let fp = simhash::fingerprint_from_subhashes(&subhashes, self.hyperplanes);
        AmbientSampleRow {
            row_id, capture_hlc: hlc,
            stream_source: StreamSourceFlag::ScreenTime as u8,
            fingerprint: fp,
            lattice_udc: "004.5".to_string(),
            payload: Vec::new(),
        }
    }
}

// MARK: - SystemTelemetry

#[derive(Debug, Clone, Copy)]
pub struct SystemTelemetrySample {
    pub cpu_percent: f32,
    pub memory_used_bytes: u64,
    pub disk_free_bytes: u64,
    pub network_up_bytes: u64,
    pub network_down_bytes: u64,
    pub battery_level: f32,
    pub thermal_state: i32,
    pub capture_time: f64,
}

pub struct SystemTelemetryExtractor<'a> {
    pub hyperplanes: &'a [HyperplaneFamily; 4],
}

impl<'a> SystemTelemetryExtractor<'a> {
    pub fn extract(&self, s: &SystemTelemetrySample, hlc: HLC, row_id: u128) -> AmbientSampleRow {
        let subhashes = [
            ((s.cpu_percent * 100.0) as u64).wrapping_mul(0x100000001B3),
            s.memory_used_bytes,
            s.network_up_bytes.wrapping_add(s.network_down_bytes),
            (s.thermal_state as u64).wrapping_mul(0x10000)
                .wrapping_add((s.battery_level * 1000.0) as u64),
        ];
        let fp = simhash::fingerprint_from_subhashes(&subhashes, self.hyperplanes);
        AmbientSampleRow {
            row_id, capture_hlc: hlc,
            stream_source: StreamSourceFlag::SystemTelemetry as u8,
            fingerprint: fp,
            lattice_udc: "004.2".to_string(),
            payload: Vec::new(),
        }
    }
}

// MARK: - Payload helper

/// Canonical key-sorted, length-prefixed binary encoding.
pub fn encode_payload(kvs: &[(&str, &str)]) -> Vec<u8> {
    let mut sorted: Vec<&(&str, &str)> = kvs.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(b.0));
    let mut out = Vec::new();
    for (k, v) in sorted {
        let k_bytes = k.as_bytes();
        let v_bytes = v.as_bytes();
        out.extend_from_slice(&(k_bytes.len() as u32).to_be_bytes());
        out.extend_from_slice(k_bytes);
        out.extend_from_slice(&(v_bytes.len() as u32).to_be_bytes());
        out.extend_from_slice(v_bytes);
    }
    out
}
