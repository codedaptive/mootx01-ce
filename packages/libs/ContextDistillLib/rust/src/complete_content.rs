//! Native complete-form-visible-v6 composition. The caller supplies the token
//! counter; every accepted transform is gated on its complete rendered output.
use crate::digest::source_digest;
#[path = "complete_content_json.rs"]
mod json;
use std::collections::HashMap;

pub const VERSION: &str = "complete-form-visible-v6";
pub const REPEAT_LEGEND: &str = "Repeated-text notation: [[TSREF:n DEFINE]] introduces one exact line; [[TSREF:n REPEAT]] repeats that complete line at its current position.\n";
pub const VISIBLE_NOTICE: &str = "Linked repeats show their original numeric link prefix before the reference; the reference still denotes the whole original entry.\n";
const TIME_INTRO: &str = "Timestamp prefixes: [Tn HH:MM] means template Tn below with HH:MM substituted. Templates are JSON strings; decode escapes. No timezone is implied.\n";
const TIME_BOUNDARY: &str = "--- Original-order text ---\n";
type Counter<'a> = dyn Fn(&str) -> u64 + 'a;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CompleteContentResult {
    pub version: String,
    pub text: String,
    pub source_sha256: String,
    pub representation_sha256: String,
    pub visible_refs: bool,
    pub original_tokens: u64,
    pub output_tokens: u64,
    pub quality_qualified: bool,
    pub model_assistance: bool,
}

pub struct CompleteContentReducer;
impl CompleteContentReducer {
    pub fn distill(
        source: &str,
        count: impl Fn(&str) -> u64,
    ) -> Result<CompleteContentResult, String> {
        let mut visible = false;
        let mut text = source.to_owned();
        if source.starts_with(&format!("{VISIBLE_NOTICE}{REPEAT_LEGEND}")) {
            expand_visible(source)?;
            visible = true;
        } else if !source.starts_with(TIME_INTRO) {
            text = clocks(&text, &count);
            text = json::tables(&text, &count);
            if !lines(source).iter().any(|l| *l == json::TABLE_LEGEND) {
                text = repeat(&text, &count)?;
            }
            text = json::blocks(&text, &count);
            text = json::declarations(&text, &count);
            text = timestamps(&text, &count);
            if text.starts_with(REPEAT_LEGEND) {
                let intermediate = expand_refs(&text)?;
                let candidate = visible_repeat(&intermediate, &count)?;
                if candidate != intermediate && count(&candidate) < count(source) {
                    if expand_visible(&candidate)? != intermediate {
                        return Err("Visible-reference reconstruction failed".into());
                    }
                    text = candidate;
                    visible = true;
                }
            }
        }
        Ok(CompleteContentResult {
            version: VERSION.into(),
            source_sha256: source_digest(source),
            representation_sha256: source_digest(&text),
            original_tokens: count(source),
            output_tokens: count(&text),
            text,
            visible_refs: visible,
            quality_qualified: false,
            model_assistance: false,
        })
    }
}

fn ws(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}
fn trim(s: &str) -> &str {
    s.trim_matches(ws)
}
// Unicode decimal-digit blocks (Nd), matching Python's Unicode \d. Keep
// numeric-looking letters/superscripts excluded: char::is_numeric is broader.
fn decimal(c: char) -> Option<u8> {
    const STARTS: &[u32] = &[
        0x30, 0x660, 0x6f0, 0x7c0, 0x966, 0x9e6, 0xa66, 0xae6, 0xb66, 0xbe6, 0xc66, 0xce6, 0xd66,
        0xde6, 0xe50, 0xed0, 0xf20, 0x1040, 0x1090, 0x17e0, 0x1810, 0x1946, 0x19d0, 0x1a80, 0x1a90,
        0x1b50, 0x1bb0, 0x1c40, 0x1c50, 0xa620, 0xa8d0, 0xa900, 0xa9d0, 0xa9f0, 0xaa50, 0xabf0,
        0xff10, 0x104a0, 0x10d30, 0x11066, 0x110f0, 0x11136, 0x111d0, 0x112f0, 0x11450, 0x114d0,
        0x11650, 0x116c0, 0x11730, 0x118e0, 0x11950, 0x11c50, 0x11d50, 0x11da0, 0x11f50, 0x16a60,
        0x16ac0, 0x16b50, 0x1d7ce, 0x1d7d8, 0x1d7e2, 0x1d7ec, 0x1d7f6, 0x1e140, 0x1e2f0, 0x1e4f0,
        0x1e950, 0x1fbf0,
    ];
    let c = c as u32;
    STARTS
        .iter()
        .find_map(|start| (c >= *start && c < *start + 10).then(|| (c - *start) as u8))
}
fn decimal_prefix(s: &str) -> usize {
    s.chars()
        .take_while(|c| decimal(*c).is_some())
        .map(char::len_utf8)
        .sum()
}
fn decimal_ascii(s: &str) -> Option<String> {
    s.chars()
        .map(|c| decimal(c).map(|v| char::from(b'0' + v)))
        .collect()
}
fn multiply_add_decimal(s: &str, multiplier: u32, addition: u32) -> String {
    let mut carry = addition;
    let mut digits = Vec::new();
    for b in s.bytes().rev() {
        let n = (b - b'0') as u32 * multiplier + carry;
        digits.push(b'0' + (n % 10) as u8);
        carry = n / 10;
    }
    while carry > 0 {
        digits.push(b'0' + (carry % 10) as u8);
        carry /= 10;
    }
    while digits.len() > 1 && digits.last() == Some(&b'0') {
        digits.pop();
    }
    digits.reverse();
    String::from_utf8(digits).unwrap()
}
/// Python splitlines(keepends=True), including CRLF and Unicode separators.
fn lines(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut it = s.char_indices().peekable();
    while let Some((i, c)) = it.next() {
        if matches!(
            c,
            '\n' | '\r'
                | '\u{b}'
                | '\u{c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        ) {
            let mut end = i + c.len_utf8();
            if c == '\r' && it.peek().map(|(_, c)| *c) == Some('\n') {
                end = it.next().unwrap().0 + 1;
            }
            out.push(&s[start..end]);
            start = end;
        }
    }
    if start < s.len() {
        out.push(&s[start..]);
    }
    out
}

// mode 0: arbitrary whitespace, 1: up to three whitespace characters,
// mode 2: up to three literal spaces.
fn fence_marker(line: &str, mode: u8) -> Option<(char, usize, usize)> {
    let mut at = 0;
    let mut n = 0;
    for c in line.chars() {
        if !(if mode == 2 { c == ' ' } else { ws(c) }) {
            break;
        }
        if mode != 0 && n == 3 {
            break;
        }
        n += 1;
        at += c.len_utf8();
    }
    let c = line[at..].chars().next()?;
    if c != '`' && c != '~' {
        return None;
    }
    let len = line[at..].chars().take_while(|v| *v == c).count();
    (len >= 3).then_some((c, len, at + len))
}
fn fence_step(line: &str, mode: u8, fence: &mut Option<(char, usize)>) -> bool {
    if let Some((c, n, end)) = fence_marker(line, mode) {
        match *fence {
            None => *fence = Some((c, n)),
            Some((old, len)) if old == c && n >= len && trim(&line[end..]).is_empty() => {
                *fence = None
            }
            _ => {}
        }
        true
    } else {
        false
    }
}
fn gated(source: &str, candidate: String, count: &Counter<'_>) -> String {
    if count(&candidate) < count(source) {
        candidate
    } else {
        source.into()
    }
}

fn clocks(source: &str, count: &Counter<'_>) -> String {
    let mut offset = 0;
    let mut marker_end = None;
    for line in source.split_inclusive('\n') {
        let raw = line.strip_suffix('\n').unwrap_or(line);
        let raw = raw.strip_suffix('\r').unwrap_or(raw);
        if raw.trim_end_matches([' ', '\t']) == "## Transcript" {
            marker_end = Some(offset + line.strip_suffix('\n').unwrap_or(line).len());
            break;
        }
        offset += line.len();
    }
    let Some(end) = marker_end else {
        return source.into();
    };
    let mut rendered = String::new();
    let mut previous = String::new();
    let mut edits = 0;
    for line in lines(&source[end..]) {
        if trim(line).is_empty() {
            rendered.push_str(line);
            continue;
        }
        let Some(close) = line.find("] ") else {
            return source.into();
        };
        if !line.starts_with('[') {
            return source.into();
        }
        let fields: Vec<_> = line[1..close].split(':').collect();
        if !(fields.len() == 2 || fields.len() == 3)
            || fields[0].chars().count() < 2
            || fields[1..].iter().any(|s| s.chars().count() != 2)
        {
            return source.into();
        }
        let Some(nums) = fields
            .iter()
            .map(|s| decimal_ascii(s))
            .collect::<Option<Vec<_>>>()
        else {
            return source.into();
        };
        let b: u32 = nums[1].parse().unwrap();
        let c: u32 = if nums.len() == 3 {
            nums[2].parse().unwrap()
        } else {
            0
        };
        if b >= 60 || c >= 60 {
            return source.into();
        }
        let value = if nums.len() == 2 {
            multiply_add_decimal(&nums[0], 60, b)
        } else {
            multiply_add_decimal(&nums[0], 3600, b * 60 + c)
        };
        if edits > 0 && (value.len(), &value) < (previous.len(), &previous) {
            return source.into();
        }
        previous = value.clone();
        edits += 1;
        rendered.push_str(&format!("{value} {}", &line[close + 2..]));
    }
    if edits < 8 {
        return source.into();
    }
    gated(source,format!("{}\nEach nonblank line starts with its elapsed time in seconds, followed by the spoken segment.\n{rendered}",&source[..end]),count)
}

fn ref_tag<'a>(line: &'a str, kind: &str) -> Option<(&'a str, &'a str)> {
    let tail = line.strip_prefix("[[TSREF:")?;
    let n = decimal_prefix(tail);
    if n == 0 {
        return None;
    }
    let rest = tail[n..].strip_prefix(kind)?;
    Some((&tail[..n], rest))
}
fn expand_refs(text: &str) -> Result<String, String> {
    let Some(body) = text.strip_prefix(REPEAT_LEGEND) else {
        return Ok(text.into());
    };
    let mut defs = HashMap::new();
    let mut out = String::new();
    for line in lines(body) {
        if let Some((id, value)) = ref_tag(line, " DEFINE]] ") {
            if defs.insert(id, value).is_some() {
                return Err("Duplicate definition".into());
            }
            out.push_str(value);
        } else if let Some((id, "\n")) = ref_tag(line, " REPEAT]]") {
            out.push_str(defs.get(id).ok_or("Forward or unknown reference")?);
        } else {
            out.push_str(line);
        }
    }
    Ok(out)
}
fn repeat(source: &str, count: &Counter<'_>) -> Result<String, String> {
    if source.contains("[[TSREF:") {
        return Ok(source.into());
    }
    let ls = lines(source);
    let mut fence = None;
    let mut groups: Vec<(&str, Vec<usize>)> = Vec::new();
    let mut group_indexes: HashMap<&str, usize> = HashMap::new();
    for (i, line) in ls.iter().enumerate() {
        if fence_step(line, 0, &mut fence) {
            continue;
        }
        let stripped = line.trim_start_matches(ws);
        let digits = decimal_prefix(stripped);
        if fence.is_some()
            || line.chars().count() < 100
            || !line.ends_with('\n')
            || stripped.starts_with(['#', '>', '|', '{', '['])
            || (digits > 0 && stripped[digits..].starts_with(['.', ')']))
            || line.starts_with("    ")
            || line.starts_with('\t')
        {
            continue;
        }
        if let Some(index) = group_indexes.get(line) {
            groups[*index].1.push(i);
        } else {
            group_indexes.insert(line, groups.len());
            groups.push((line, vec![i]));
        }
    }
    let mut replacement = HashMap::new();
    let mut n = 0;
    for (line, indexes) in groups {
        if indexes.len() < 2 {
            continue;
        }
        let id = n + 1;
        let define = format!("[[TSREF:{id} DEFINE]] {line}");
        let repeat = format!("[[TSREF:{id} REPEAT]]\n");
        if count(&define) + (indexes.len() as u64 - 1) * count(&repeat)
            >= indexes.len() as u64 * count(line)
        {
            continue;
        }
        n = id;
        replacement.insert(indexes[0], define);
        for i in &indexes[1..] {
            replacement.insert(*i, repeat.clone());
        }
    }
    if n == 0 {
        return Ok(source.into());
    }
    let mut candidate = REPEAT_LEGEND.to_owned();
    for (i, line) in ls.iter().enumerate() {
        candidate.push_str(replacement.get(&i).map(String::as_str).unwrap_or(line));
    }
    let candidate = gated(source, candidate, count);
    if candidate != source && expand_refs(&candidate)? != source {
        return Err("Repeated-text reconstruction failed".into());
    }
    Ok(candidate)
}
fn linked_id(value: &str) -> Option<&str> {
    let rest = value.strip_prefix("- [[")?;
    let n = rest.bytes().take_while(|c| c.is_ascii_digit()).count();
    if n == 0 {
        return None;
    }
    let suffix = rest[n..].strip_prefix('-')?;
    let end = suffix.find("]]")?;
    if end == 0 || suffix[..end].contains([']', '\n']) {
        return None;
    }
    Some(&rest[..n])
}
fn expand_visible(source: &str) -> Result<String, String> {
    let Some(body) = source.strip_prefix(&format!("{VISIBLE_NOTICE}{REPEAT_LEGEND}")) else {
        return Ok(source.into());
    };
    let mut defs = HashMap::new();
    let mut output = REPEAT_LEGEND.to_owned();
    for line in lines(body) {
        if let Some((id, value)) = ref_tag(line, " DEFINE]] ") {
            if let Some(link) = linked_id(value) {
                defs.insert(id, link);
            }
        }
        if let Some(rest) = line.strip_prefix("entry ") {
            if let Some((link, reference)) = rest.split_once(": ") {
                if !link.is_empty() && link.bytes().all(|c| c.is_ascii_digit()) {
                    if let Some((id, "\n")) = ref_tag(reference, " REPEAT]]") {
                        if defs.get(id).copied() != Some(link) {
                            return Err("Visible identity mismatch".into());
                        }
                        output.push_str(reference);
                        continue;
                    }
                }
            }
        }
        output.push_str(line);
    }
    expand_refs(&output)
}
fn visible_repeat(source: &str, count: &Counter<'_>) -> Result<String, String> {
    if source.contains(VISIBLE_NOTICE) {
        return Ok(source.into());
    }
    let prior = repeat(source, count)?;
    if prior == source {
        return Ok(source.into());
    }
    let mut defs = HashMap::new();
    let mut out = format!("{VISIBLE_NOTICE}{REPEAT_LEGEND}");
    let mut cues = 0;
    for line in lines(
        prior
            .strip_prefix(REPEAT_LEGEND)
            .ok_or("Missing repeat legend")?,
    ) {
        if let Some((id, value)) = ref_tag(line, " DEFINE]] ") {
            if let Some(link) = linked_id(value) {
                defs.insert(id, link);
            }
        }
        if let Some((id, "\n")) = ref_tag(line, " REPEAT]]") {
            if let Some(link) = defs.get(id) {
                out.push_str(&format!("entry {link}: "));
                cues += 1;
            }
        }
        out.push_str(line);
    }
    if cues == 0 {
        return Ok(source.into());
    }
    Ok(gated(source, out, count))
}

fn timestamp_prefix(line: &str) -> Option<(String, &str, usize)> {
    let mut it = line.char_indices();
    let mut end = 0;
    let mut date_end = 0;
    let mut time_start = 0;
    let mut time_end = 0;
    for i in 0..18 {
        let (at, c) = it.next()?;
        let valid = match i {
            4 | 7 => c == '-',
            10 => c == 'T',
            13 => c == ':',
            16 => c == ' ',
            17 => c == '(',
            _ => decimal(c).is_some(),
        };
        if !valid {
            return None;
        }
        end = at + c.len_utf8();
        if i == 9 {
            date_end = end;
        }
        if i == 11 {
            time_start = at;
        }
        if i == 15 {
            time_end = end;
        }
    }
    let rest = &line[end..];
    let close = rest.find(')')?;
    if close == 0 || rest[..close].contains('\n') || !rest[close..].starts_with(") — ") {
        return None;
    }
    let end = end + close + ") — ".len();
    Some((
        format!("{}THH:MM{}", &line[..date_end], &line[time_end..end]),
        &line[time_start..time_end],
        end,
    ))
}
fn timestamps(source: &str, count: &Counter<'_>) -> String {
    if source.contains("[T") || source.contains(TIME_INTRO) || source.contains(TIME_BOUNDARY) {
        return source.into();
    }
    let mut groups: Vec<(String, u64)> = Vec::new();
    let mut fence = None;
    for line in lines(source) {
        if fence_step(line, 2, &mut fence) || fence.is_some() {
            continue;
        }
        if let Some((template, _, _)) = timestamp_prefix(line) {
            if template.matches("HH:MM").count() != 1 {
                continue;
            }
            if let Some((_, n)) = groups.iter_mut().find(|(t, _)| *t == template) {
                *n += 1;
            } else {
                groups.push((template, 1));
            }
        }
    }
    let mut selected = Vec::new();
    let mut definitions = String::new();
    for (template, n) in groups {
        let id = selected.len() + 1;
        let definition = format!("T{id} = {}\n", serde_json::to_string(&template).unwrap());
        if n < 2
            || count(&definition) + n * count(&format!("[T{id} 00:00] "))
                >= n * count(&template.replace("HH:MM", "00:00"))
        {
            continue;
        }
        selected.push(template);
        definitions.push_str(&definition);
    }
    let mut body = String::new();
    fence = None;
    let mut changed = false;
    for line in lines(source) {
        if !fence_step(line, 2, &mut fence) && fence.is_none() {
            if let Some((template, time, end)) = timestamp_prefix(line) {
                if let Some(i) = selected.iter().position(|t| *t == template) {
                    body.push_str(&format!("[T{} {time}] {}", i + 1, &line[end..]));
                    changed = true;
                    continue;
                }
            }
        }
        body.push_str(line);
    }
    if !changed {
        return source.into();
    }
    gated(
        source,
        format!("{TIME_INTRO}{definitions}{TIME_BOUNDARY}{body}"),
        count,
    )
}
