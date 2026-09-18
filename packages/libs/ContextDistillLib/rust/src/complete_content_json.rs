//! Ordered, strict integer-only JSON for the complete-content transforms.
//! Objects use pairs, avoiding serde_json's default sorted-map representation.
//! JSON values at nesting depth 128 conservatively preserve the source instead
//! of recursing farther on the native thread stack. This is a narrower domain
//! than the Python interpreter's implementation-dependent recursion limit.
use super::{fence_step, gated, lines, trim, Counter};
pub(super) const TABLE_LEGEND:&str="Compact JSON: $packedTable contains columns and rows. Each row is one object; values match columns in order. All other JSON is unchanged.\n";
const DECL_LEGEND:&str="$swiftDeclarations rows follow columns. Original kind and name fields are duplicated in each Swift signature; originalColumns records their original positions. Kind is the declaration keyword; name is its following identifier, or empty for init and non-identifier func names. No declaration text is omitted.\n";
// Preserve source boundaries even where the experimental Python oracle drops
// non-LF endings. Joining compact JSON to following prose changes the record.
fn ending(s: &str) -> &str {
    if s.ends_with("\r\n") {
        return &s[s.len() - 2..];
    }
    match s.chars().next_back() {
        Some(
            c @ ('\n' | '\r' | '\u{b}' | '\u{c}' | '\u{1c}' | '\u{1d}' | '\u{1e}' | '\u{85}'
            | '\u{2028}' | '\u{2029}'),
        ) => &s[s.len() - c.len_utf8()..],
        _ => "",
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum J {
    Object(Vec<(String, J)>),
    Array(Vec<J>),
    String(String),
    Scalar(String),
}
impl J {
    fn get(&self, key: &str) -> Option<&J> {
        if let J::Object(p) = self {
            p.iter().find(|(k, _)| k == key).map(|(_, v)| v)
        } else {
            None
        }
    }
    fn array(&self) -> Option<&[J]> {
        if let J::Array(a) = self {
            Some(a)
        } else {
            None
        }
    }
    fn string(&self) -> Option<&str> {
        if let J::String(s) = self {
            Some(s)
        } else {
            None
        }
    }
    fn dump(&self) -> String {
        match self {
            J::Object(p) => format!(
                "{{{}}}",
                p.iter()
                    .map(|(k, v)| format!("{}:{}", serde_json::to_string(k).unwrap(), v.dump()))
                    .collect::<Vec<_>>()
                    .join(",")
            ),
            J::Array(a) => format!("[{}]", a.iter().map(J::dump).collect::<Vec<_>>().join(",")),
            J::String(s) => serde_json::to_string(s).unwrap(),
            J::Scalar(s) => s.clone(),
        }
    }
}
struct Parser<'a> {
    s: &'a str,
    at: usize,
}
impl<'a> Parser<'a> {
    fn whitespace(&mut self) {
        while self
            .s
            .as_bytes()
            .get(self.at)
            .is_some_and(|b| matches!(b, b' ' | b'\n' | b'\r' | b'\t'))
        {
            self.at += 1;
        }
    }
    fn take(&mut self, b: u8) -> bool {
        self.whitespace();
        if self.s.as_bytes().get(self.at) == Some(&b) {
            self.at += 1;
            true
        } else {
            false
        }
    }
    fn string(&mut self) -> Option<String> {
        self.whitespace();
        let start = self.at;
        if !self.take(b'"') {
            return None;
        }
        let mut escaped = false;
        while let Some(&b) = self.s.as_bytes().get(self.at) {
            self.at += 1;
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                return serde_json::from_str(&self.s[start..self.at]).ok();
            }
        }
        None
    }
    fn value(&mut self, depth: usize) -> Option<J> {
        if depth >= 128 {
            return None;
        }
        self.whitespace();
        match *self.s.as_bytes().get(self.at)? {
            b'"' => Some(J::String(self.string()?)),
            b'{' => {
                self.at += 1;
                let mut p = Vec::new();
                if self.take(b'}') {
                    return Some(J::Object(p));
                }
                loop {
                    let key = self.string()?;
                    if p.iter().any(|(k, _)| *k == key) || !self.take(b':') {
                        return None;
                    }
                    let v = self.value(depth + 1)?;
                    p.push((key, v));
                    if self.take(b'}') {
                        break;
                    }
                    if !self.take(b',') {
                        return None;
                    }
                }
                Some(J::Object(p))
            }
            b'[' => {
                self.at += 1;
                let mut a = Vec::new();
                if self.take(b']') {
                    return Some(J::Array(a));
                }
                loop {
                    a.push(self.value(depth + 1)?);
                    if self.take(b']') {
                        break;
                    }
                    if !self.take(b',') {
                        return None;
                    }
                }
                Some(J::Array(a))
            }
            b't' | b'f' | b'n' => {
                for lit in ["true", "false", "null"] {
                    if self.s[self.at..].starts_with(lit) {
                        self.at += lit.len();
                        return Some(J::Scalar(lit.into()));
                    }
                }
                None
            }
            b'-' | b'0'..=b'9' => {
                let start = self.at;
                if self.s.as_bytes()[self.at] == b'-' {
                    self.at += 1;
                }
                let digits = self.at;
                while self
                    .s
                    .as_bytes()
                    .get(self.at)
                    .is_some_and(u8::is_ascii_digit)
                {
                    self.at += 1;
                }
                let v = &self.s[start..self.at];
                if digits == self.at
                    || self.at - digits > 4300
                    || v == "-0"
                    || (self.at - digits > 1 && self.s.as_bytes()[digits] == b'0')
                {
                    return None;
                }
                Some(J::Scalar(v.into()))
            }
            _ => None,
        }
    }
}
fn parse(s: &str) -> Option<J> {
    let mut p = Parser { s, at: 0 };
    let v = p.value(0)?;
    p.whitespace();
    (p.at == s.len()).then_some(v)
}
fn object(p: Vec<(&str, J)>) -> J {
    J::Object(p.into_iter().map(|(k, v)| (k.into(), v)).collect())
}
fn encode(value: &J) -> Option<J> {
    match value {
        J::Object(p) => {
            if p.iter().any(|(k, _)| k == "$packedTable") {
                return None;
            }
            Some(J::Object(
                p.iter()
                    .map(|(k, v)| Some((k.clone(), encode(v)?)))
                    .collect::<Option<_>>()?,
            ))
        }
        J::Array(a) => {
            if a.len() >= 3 {
                if let J::Object(first) = &a[0] {
                    let cols: Vec<_> = first.iter().map(|(k, _)| k).collect();
                    if !cols.is_empty()&&a.iter().all(|v|matches!(v,J::Object(p) if p.iter().map(|(k,_)|k).collect::<Vec<_>>()==cols)) {
                if cols.iter().any(|k|*k=="$packedTable"){return None;}
                let mut rows=Vec::new();for v in a {if let J::Object(p)=v {rows.push(J::Array(p.iter().map(|(_,v)|encode(v)).collect::<Option<_>>()?));}}
                return Some(object(vec![("$packedTable",object(vec![("columns",J::Array(cols.into_iter().map(|k|J::String(k.clone())).collect())),("rows",J::Array(rows))]))]));
            }
                }
            }
            Some(J::Array(a.iter().map(encode).collect::<Option<_>>()?))
        }
        _ => Some(value.clone()),
    }
}
fn unpack(value: &J) -> Option<J> {
    match value {
        J::Object(p) => {
            if let Some(table) = value.get("$packedTable") {
                if p.len() != 1 {
                    return None;
                }
                let J::Object(fields) = table else {
                    return None;
                };
                if fields.len() != 2 {
                    return None;
                }
                let columns = table.get("columns")?.array()?;
                let rows = table.get("rows")?.array()?;
                let keys: Vec<_> = columns.iter().map(J::string).collect::<Option<_>>()?;
                if keys.is_empty() || keys.iter().enumerate().any(|(i, k)| keys[..i].contains(k)) {
                    return None;
                }
                let mut out = Vec::new();
                for row in rows {
                    let row = row.array()?;
                    if row.len() != keys.len() {
                        return None;
                    }
                    out.push(J::Object(
                        keys.iter()
                            .zip(row)
                            .map(|(k, v)| Some(((*k).into(), unpack(v)?)))
                            .collect::<Option<_>>()?,
                    ));
                }
                return Some(J::Array(out));
            }
            Some(J::Object(
                p.iter()
                    .map(|(k, v)| Some((k.clone(), unpack(v)?)))
                    .collect::<Option<_>>()?,
            ))
        }
        J::Array(a) => Some(J::Array(a.iter().map(unpack).collect::<Option<_>>()?)),
        _ => Some(value.clone()),
    }
}
pub(super) fn tables(source: &str, count: &Counter<'_>) -> String {
    let mut fence = None;
    let mut out = String::new();
    for line in lines(source) {
        if fence_step(line, 0, &mut fence) || fence.is_some() || !trim(line).starts_with(['{', '['])
        {
            out.push_str(line);
            continue;
        }
        let candidate = parse(trim(line)).and_then(|v| {
            let e = encode(&v)?;
            if e == v || unpack(&e)? != v {
                return None;
            }
            Some(format!("{TABLE_LEGEND}{}{}", e.dump(), ending(line)))
        });
        out.push_str(candidate.as_deref().unwrap_or(line));
    }
    gated(source, out, count)
}
fn block_end(source: &str, start: usize) -> Option<usize> {
    let mut stack = Vec::new();
    let mut quoted = false;
    let mut escaped = false;
    for (i, b) in source.bytes().enumerate().skip(start) {
        if quoted {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                quoted = false;
            }
        } else {
            match b {
                b'"' => quoted = true,
                b'{' | b'[' => stack.push(b),
                b'}' | b']' => {
                    if stack.pop() != Some(if b == b'}' { b'{' } else { b'[' }) {
                        return None;
                    }
                    if stack.is_empty() {
                        return Some(i + 1);
                    }
                }
                _ => {}
            }
        }
    }
    None
}
pub(super) fn blocks(source: &str, count: &Counter<'_>) -> String {
    let ls = lines(source);
    let mut offsets = Vec::new();
    let mut cursor = 0;
    for l in &ls {
        offsets.push(cursor);
        cursor += l.len();
    }
    let mut out = String::new();
    let mut fence = None;
    let mut i = 0;
    while i < ls.len() {
        let line = ls[i];
        let marker = fence_step(line, 1, &mut fence);
        let stripped = line.trim_start_matches([' ', '\t']);
        if marker || fence.is_some() || !stripped.starts_with(['{', '[']) {
            out.push_str(line);
            i += 1;
            continue;
        }
        let start = offsets[i] + line.len() - stripped.len();
        let Some(end) = block_end(source, start) else {
            out.push_str(&source[offsets[i]..]);
            break;
        };
        let mut j = i + 1;
        while j < ls.len() && offsets[j] < end {
            j += 1;
        }
        let boundary = if j < ls.len() {
            offsets[j]
        } else {
            source.len()
        };
        let original = &source[offsets[i]..boundary];
        let candidate = if !trim(&source[end..boundary]).is_empty() {
            None
        } else {
            parse(&source[start..end]).and_then(|v| {
                let e = encode(&v)?;
                if unpack(&e)? != v {
                    return None;
                }
                Some(format!(
                    "{}{}{}",
                    if e != v { TABLE_LEGEND } else { "" },
                    e.dump(),
                    ending(original)
                ))
            })
        };
        if let Some(c) = candidate {
            if count(&c) < count(original) {
                out.push_str(&c);
            } else {
                out.push_str(original);
            }
        } else {
            out.push_str(original);
        }
        i = j;
    }
    gated(source, out, count)
}
fn fields(signature: &str) -> Option<(&str, &str)> {
    const MODS: &[&str] = &[
        "public",
        "private",
        "fileprivate",
        "internal",
        "open",
        "static",
        "class",
        "final",
        "mutating",
        "nonmutating",
        "override",
        "required",
        "convenience",
        "indirect",
        "lazy",
    ];
    const KINDS: &[&str] = &[
        "func",
        "let",
        "var",
        "enum",
        "init",
        "struct",
        "extension",
        "typealias",
        "actor",
        "protocol",
        "class",
    ];
    // Regex greedily consumes modifiers but can backtrack for `class Foo`.
    let mut positions = vec![0];
    let mut pos = 0;
    loop {
        let rem = &signature[pos..];
        let n = rem
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .map(char::len_utf8)
            .sum::<usize>();
        if n == 0 || !MODS.contains(&&rem[..n]) {
            break;
        }
        let after = &rem[n..];
        let ws = after
            .chars()
            .take_while(|c| super::ws(*c))
            .map(char::len_utf8)
            .sum::<usize>();
        if ws == 0 {
            break;
        }
        pos += n + ws;
        positions.push(pos);
    }
    for pos in positions.into_iter().rev() {
        let rem = &signature[pos..];
        for kind in KINDS {
            if let Some(tail) = rem.strip_prefix(kind) {
                if tail
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_alphanumeric() || c == '_')
                {
                    continue;
                }
                if *kind == "init" {
                    return Some((kind, ""));
                }
                let n = tail
                    .chars()
                    .take_while(|c| super::ws(*c))
                    .map(char::len_utf8)
                    .sum::<usize>();
                let rest = &tail[n..];
                if n > 0
                    && rest
                        .chars()
                        .next()
                        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
                {
                    let len = rest
                        .bytes()
                        .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_')
                        .count();
                    return Some((kind, &rest[..len]));
                }
                if *kind == "func" {
                    return Some((kind, ""));
                }
                return None;
            }
        }
    }
    None
}
fn declarations_encode(value: &J) -> Option<J> {
    match value {
        J::Array(a) => Some(J::Array(
            a.iter().map(declarations_encode).collect::<Option<_>>()?,
        )),
        J::Object(p) => {
            if value.get("$swiftDeclarations").is_some() {
                return None;
            }
            if p.len() == 1 {
                if let Some(table) = value.get("$packedTable") {
                    let columns = table.get("columns")?.array()?;
                    let rows = table.get("rows")?.array()?;
                    let keys: Vec<_> = columns.iter().map(J::string).collect::<Option<_>>()?;
                    if !rows.is_empty() {
                        if let (Some(k), Some(n), Some(s)) = (
                            keys.iter().position(|x| *x == "kind"),
                            keys.iter().position(|x| *x == "name"),
                            keys.iter().position(|x| *x == "signature"),
                        ) {
                            let matches = rows.iter().all(|row| {
                                let Some(r) = row.array() else {
                                    return false;
                                };
                                if r.len() != keys.len() {
                                    return false;
                                }
                                r[s].string().and_then(fields).is_some_and(|(kind, name)| {
                                    r[k].string() == Some(kind) && r[n].string() == Some(name)
                                })
                            });
                            if matches {
                                let kept: Vec<_> =
                                    (0..keys.len()).filter(|i| *i != k && *i != n).collect();
                                let mut new_rows = Vec::new();
                                for row in rows {
                                    let r = row.array()?;
                                    new_rows.push(J::Array(
                                        kept.iter()
                                            .map(|i| declarations_encode(&r[*i]))
                                            .collect::<Option<_>>()?,
                                    ));
                                }
                                return Some(object(vec![(
                                    "$swiftDeclarations",
                                    object(vec![
                                        (
                                            "columns",
                                            J::Array(
                                                kept.iter().map(|i| columns[*i].clone()).collect(),
                                            ),
                                        ),
                                        ("originalColumns", J::Array(columns.to_vec())),
                                        ("rows", J::Array(new_rows)),
                                    ]),
                                )]));
                            }
                        }
                    }
                }
            }
            Some(J::Object(
                p.iter()
                    .map(|(k, v)| Some((k.clone(), declarations_encode(v)?)))
                    .collect::<Option<_>>()?,
            ))
        }
        _ => Some(value.clone()),
    }
}
pub(super) fn declarations(source: &str, count: &Counter<'_>) -> String {
    let ls = lines(source);
    let mut fence = None;
    let mut i = 0;
    let mut out = String::new();
    while i < ls.len() {
        let line = ls[i];
        if fence_step(line, 2, &mut fence) {
            out.push_str(line);
            i += 1;
            continue;
        }
        if fence.is_none() && line == TABLE_LEGEND && i + 1 < ls.len() {
            let candidate = parse(trim(ls[i + 1])).and_then(|v| {
                unpack(&v)?;
                let p = declarations_encode(&v)?;
                (p != v).then(|| p.dump())
            });
            if let Some(c) = candidate {
                out.push_str(line);
                out.push_str(DECL_LEGEND);
                out.push_str(&c);
                out.push_str(ending(ls[i + 1]));
                i += 2;
                continue;
            }
        }
        out.push_str(line);
        i += 1;
    }
    gated(source, out, count)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parser_domain_matches_native_swift() {
        assert!(parse(&"9".repeat(4300)).is_some());
        assert!(parse(&"9".repeat(4301)).is_none());
        assert!(parse(&format!("-{}", "9".repeat(4300))).is_some());
        assert!(parse(&format!("{}0{}", "[".repeat(127), "]".repeat(127))).is_some());
        assert!(parse(&format!("{}0{}", "[".repeat(128), "]".repeat(128))).is_none());
    }
    #[test]
    fn every_json_transform_preserves_source_line_terminators() {
        let count = |s: &str| s.len() as u64;
        let rows = (0..45).map(|i|format!("{{\"kind\":\"func\",\"name\":\"function{i}\",\"signature\":\"public func function{i}()\",\"longRepeatedFieldName\":{i}}}")).collect::<Vec<_>>().join(",");
        let json = format!("[{rows}]");
        for separator in [
            "\n", "\r\n", "\r", "\u{b}", "\u{c}", "\u{1c}", "\u{1d}", "\u{1e}", "\u{85}",
            "\u{2028}", "\u{2029}",
        ] {
            let source = format!("{json}{separator}Following prose.");
            let table = tables(&source, &count);
            assert_ne!(table, source);
            assert!(
                table.ends_with(&format!("{separator}Following prose.")),
                "tables {separator:?}"
            );
            let declared = declarations(&table, &count);
            assert!(declared.contains("$swiftDeclarations rows"));
            assert!(
                declared.ends_with(&format!("{separator}Following prose.")),
                "declarations {separator:?}"
            );
            let source=format!("{{\n    \"someKey\":    123,\n    \"anotherKey\":    true\n}}{separator}Following prose.");
            let block = blocks(&source, &count);
            assert_eq!(
                block,
                format!("{{\"someKey\":123,\"anotherKey\":true}}{separator}Following prose."),
                "blocks {separator:?}"
            );
        }
    }
    #[test]
    fn strict_ordered_json() {
        let v = parse("{\"z\":9999999999999999999999999999999999,\"a\":1}").unwrap();
        assert_eq!(
            v.dump(),
            "{\"z\":9999999999999999999999999999999999,\"a\":1}"
        );
        for s in ["{\"a\":1,\"a\":2}", "-0", "1.0", "1e2", "NaN", "01"] {
            assert!(parse(s).is_none(), "{s}");
        }
    }
    #[test]
    fn swift_fields() {
        assert_eq!(fields("public class Foo"), Some(("class", "Foo")));
        assert_eq!(fields("public static func + (a: Int)"), Some(("func", "")));
        assert_eq!(fields("init?(x: Int)"), Some(("init", "")));
        assert_eq!(fields(" let x"), None);
    }
}
