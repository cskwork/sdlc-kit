//! JSON as JavaScript reads and writes it: object key order, lone surrogates and number text match
//! JSON.parse and JSON.stringify, because todo.md holds JSON lines the Node CLI writes too.
use std::collections::HashMap;

/// A JavaScript string from JSON, as WTF-8: UTF-8 in which a lone surrogate is kept as three bytes.
#[derive(Clone, PartialEq, Eq, Hash, Debug, Default)]
pub struct Text(Vec<u8>);

impl From<&str> for Text {
    fn from(text: &str) -> Text { Text(text.as_bytes().to_vec()) }
}

impl Text {
    /// Code points, lone surrogates included.
    fn points(&self) -> Vec<u32> {
        let (bytes, mut out, mut i) = (&self.0, Vec::with_capacity(self.0.len()), 0);
        while i < bytes.len() {
            let b = bytes[i] as u32;
            let (first, more) = if b < 0x80 { (b, 0) } else if b < 0xe0 { (b & 0x1f, 1) } else if b < 0xf0 { (b & 0x0f, 2) } else { (b & 0x07, 3) };
            let mut point = first;
            for k in 1..=more { point = point << 6 | (bytes[i + k] as u32 & 0x3f); }
            out.push(point);
            i += more + 1;
        }
        out
    }
    fn push_unit(&mut self, unit: u32) {
        match char::from_u32(unit) {
            Some(c) => self.0.extend_from_slice(c.encode_utf8(&mut [0; 4]).as_bytes()),
            None => self.0.extend_from_slice(&[0xe0 | (unit >> 12) as u8, 0x80 | (unit >> 6 & 0x3f) as u8, 0x80 | (unit & 0x3f) as u8]),
        }
    }
    /// The text as Node writes it to a file: a lone surrogate becomes U+FFFD.
    pub fn lossy(&self) -> String { self.points().into_iter().map(|p| char::from_u32(p).unwrap_or('\u{fffd}')).collect() }
    pub fn is_empty(&self) -> bool { self.0.is_empty() }
    pub fn has_any(&self, chars: &[u8]) -> bool { self.0.iter().any(|b| chars.contains(b)) }
    /// `.length` in JavaScript: UTF-16 units.
    pub fn units(&self) -> usize { self.points().into_iter().map(|p| if p > 0xffff { 2 } else { 1 }).sum() }
    pub fn trim(&self) -> Text {
        match std::str::from_utf8(&self.0) {
            Ok(text) => Text::from(super::js::trim(text)),
            Err(_) => {
                let points = self.points();
                let space = |p: &u32| char::from_u32(*p).is_some_and(super::js::is_space);
                let from = points.iter().position(|p| !space(p)).unwrap_or(points.len());
                let to = points.iter().rposition(|p| !space(p)).map_or(from, |i| i + 1);
                let mut out = Text::default();
                for p in &points[from..to] { out.push_unit(*p); }
                out
            }
        }
    }
    fn write(&self, out: &mut String) {
        match std::str::from_utf8(&self.0) {
            Ok(text) => quote(text, out),
            Err(_) => {
                out.push('"');
                for p in self.points() {
                    match char::from_u32(p) { Some(c) => escape(c, out), None => out.push_str(&format!("\\u{p:04x}")) }
                }
                out.push('"');
            }
        }
    }
}

fn escape(c: char, out: &mut String) {
    match c {
        '"' => out.push_str("\\\""),
        '\\' => out.push_str("\\\\"),
        '\u{8}' => out.push_str("\\b"),
        '\t' => out.push_str("\\t"),
        '\n' => out.push_str("\\n"),
        '\u{c}' => out.push_str("\\f"),
        '\r' => out.push_str("\\r"),
        c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
        c => out.push(c),
    }
}

/// JSON.stringify of a string.
pub fn quote(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() { escape(c, out); }
    out.push('"');
}

#[derive(Clone, PartialEq, Debug)]
pub enum Json { Null, Bool(bool), Num(f64), Str(Text), Arr(Vec<Json>), Obj(Vec<(Text, Json)>) }

impl Json {
    pub fn str(text: &str) -> Json { Json::Str(text.into()) }
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self { Json::Obj(entries) => entries.iter().find(|(k, _)| k.0 == key.as_bytes()).map(|(_, v)| v), _ => None }
    }
    /// The string as Node writes it.
    pub fn text(&self) -> Option<String> { match self { Json::Str(text) => Some(text.lossy()), _ => None } }
    pub fn write(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Json::Num(n) => out.push_str(&number(*n)),
            Json::Str(text) => text.write(out),
            Json::Arr(list) => {
                out.push('[');
                for (i, v) in list.iter().enumerate() { if i > 0 { out.push(','); } v.write(out); }
                out.push(']');
            }
            Json::Obj(entries) => {
                out.push('{');
                for (i, (k, v)) in entries.iter().enumerate() { if i > 0 { out.push(','); } k.write(out); out.push(':'); v.write(out); }
                out.push('}');
            }
        }
    }
    pub fn stringify(&self) -> String { let mut out = String::new(); self.write(&mut out); out }
}

/// An object literal in the order written; its keys are never integers.
pub fn object(entries: Vec<(&str, Json)>) -> Json { Json::Obj(entries.into_iter().map(|(k, v)| (k.into(), v)).collect()) }

/// A number as JSON.stringify writes it.
fn number(n: f64) -> String {
    if !n.is_finite() { return "null".into(); }
    if n == 0.0 { return "0".into(); }
    let text = format!("{:e}", n.abs());
    let (mantissa, exponent) = text.split_once('e').unwrap_or((&text, "0"));
    let digits = mantissa.replace('.', "");
    let (k, n10) = (digits.len() as i32, exponent.parse::<i32>().unwrap_or(0) + 1);
    let body = if k <= n10 && n10 <= 21 { format!("{digits}{}", "0".repeat((n10 - k) as usize)) }
        else if 0 < n10 && n10 <= 21 { format!("{}.{}", &digits[..n10 as usize], &digits[n10 as usize..]) }
        else if -6 < n10 && n10 <= 0 { format!("0.{}{digits}", "0".repeat(-n10 as usize)) }
        else {
            let e = n10 - 1;
            let sign = if e < 0 { '-' } else { '+' };
            if k == 1 { format!("{digits}e{sign}{}", e.abs()) } else { format!("{}.{}e{sign}{}", &digits[..1], &digits[1..], e.abs()) }
        };
    if n < 0.0 { format!("-{body}") } else { body }
}

/// Nesting JSON.parse accepts but nothing here needs; deeper input is refused instead of exhausting the stack.
const DEPTH: usize = 512;

/// JSON.parse; None where it would throw.
pub fn parse(text: &str) -> Option<Json> {
    let mut p = Parser { bytes: text.as_bytes(), text, at: 0 };
    p.space();
    let value = p.value(0)?;
    p.space();
    (p.at == p.bytes.len()).then_some(value)
}

struct Parser<'a> { bytes: &'a [u8], text: &'a str, at: usize }

impl Parser<'_> {
    fn peek(&self) -> Option<u8> { self.bytes.get(self.at).copied() }
    fn space(&mut self) { while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) { self.at += 1; } }
    fn eat(&mut self, b: u8) -> Option<()> { if self.peek() == Some(b) { self.at += 1; Some(()) } else { None } }
    fn word(&mut self, word: &str, value: Json) -> Option<Json> {
        self.bytes[self.at..].starts_with(word.as_bytes()).then(|| { self.at += word.len(); value })
    }
    fn value(&mut self, depth: usize) -> Option<Json> {
        if depth > DEPTH { return None; }
        match self.peek()? {
            b'n' => self.word("null", Json::Null),
            b't' => self.word("true", Json::Bool(true)),
            b'f' => self.word("false", Json::Bool(false)),
            b'"' => self.string().map(Json::Str),
            b'[' => {
                self.at += 1;
                let mut list = Vec::new();
                self.space();
                if self.eat(b']').is_some() { return Some(Json::Arr(list)); }
                loop {
                    self.space();
                    list.push(self.value(depth + 1)?);
                    self.space();
                    if self.eat(b',').is_some() { continue; }
                    self.eat(b']')?;
                    return Some(Json::Arr(list));
                }
            }
            b'{' => {
                self.at += 1;
                let (mut entries, mut index) = (Vec::new(), HashMap::new());
                self.space();
                if self.eat(b'}').is_some() { return Some(Json::Obj(entries)); }
                loop {
                    self.space();
                    let key = self.string()?;
                    self.space();
                    self.eat(b':')?;
                    self.space();
                    let value = self.value(depth + 1)?;
                    // A repeated key keeps its first place and its last value.
                    match index.get(&key) {
                        Some(i) => { let entry: &mut (Text, Json) = &mut entries[*i]; entry.1 = value; }
                        None => { index.insert(key.clone(), entries.len()); entries.push((key, value)); }
                    }
                    self.space();
                    if self.eat(b',').is_some() { continue; }
                    self.eat(b'}')?;
                    order(&mut entries);
                    return Some(Json::Obj(entries));
                }
            }
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }
    fn digits(&mut self) -> Option<()> {
        let from = self.at;
        while matches!(self.peek(), Some(b'0'..=b'9')) { self.at += 1; }
        (self.at > from).then_some(())
    }
    fn number(&mut self) -> Option<Json> {
        let from = self.at;
        let _ = self.eat(b'-');
        if self.eat(b'0').is_none() { self.digits()?; }
        if self.eat(b'.').is_some() { self.digits()?; }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.at += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) { self.at += 1; }
            self.digits()?;
        }
        self.text[from..self.at].parse().ok().map(Json::Num)
    }
    fn hex(&mut self) -> Option<u32> {
        let digits = self.bytes.get(self.at..self.at + 4)?;
        if !digits.iter().all(u8::is_ascii_hexdigit) { return None; }
        self.at += 4;
        u32::from_str_radix(std::str::from_utf8(digits).ok()?, 16).ok()
    }
    fn string(&mut self) -> Option<Text> {
        self.eat(b'"')?;
        let mut out = Text::default();
        loop {
            let from = self.at;
            while !matches!(self.peek()?, b'"' | b'\\' | 0..=0x1f) { self.at += 1; }
            out.0.extend_from_slice(&self.bytes[from..self.at]);
            match self.peek()? {
                b'"' => { self.at += 1; return Some(out); }
                b'\\' => {
                    self.at += 2;
                    match self.bytes.get(self.at - 1)? {
                        b'"' => out.0.push(b'"'),
                        b'\\' => out.0.push(b'\\'),
                        b'/' => out.0.push(b'/'),
                        b'b' => out.0.push(8),
                        b'f' => out.0.push(12),
                        b'n' => out.0.push(b'\n'),
                        b'r' => out.0.push(b'\r'),
                        b't' => out.0.push(b'\t'),
                        b'u' => {
                            let unit = self.hex()?;
                            if (0xd800..0xdc00).contains(&unit) && self.bytes[self.at..].starts_with(b"\\u") {
                                let back = self.at;
                                self.at += 2;
                                let low = self.hex()?;
                                if (0xdc00..0xe000).contains(&low) { out.push_unit(0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00)); continue; }
                                self.at = back;
                            }
                            out.push_unit(unit);
                        }
                        _ => return None,
                    }
                }
                _ => return None,
            }
        }
    }
}

/// JavaScript lists integer keys first, ascending, then the others as inserted.
pub fn order(entries: &mut [(Text, Json)]) {
    let index = |key: &Text| -> Option<u32> {
        let text = std::str::from_utf8(&key.0).ok()?;
        let canonical = text == "0" || (!text.starts_with('0') && !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()));
        if !canonical { return None; }
        text.parse::<u32>().ok().filter(|n| *n < u32::MAX)
    };
    entries.sort_by_key(|(k, _)| index(k).map_or((1, 0), |n| (0, n)));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_and_writes_as_javascript_does() {
        let round = |text: &str| parse(text).map(|v| v.stringify());
        assert_eq!(round(r#"{"b":1,"2":0,"a":1,"1":0,"b":3}"#).unwrap(), r#"{"1":0,"2":0,"b":3,"a":1}"#);
        assert_eq!(round(r#"["\ud800x","\ud83d\ude00","\u0001\u2028\/"]"#).unwrap(), "[\"\\ud800x\",\"😀\",\"\\u0001\u{2028}/\"]");
        assert_eq!(round("[1e21,123456789012345680000,1.5e-7,0.000001,-0,1e400,100,1.0,5e-324]").unwrap(),
            "[1e+21,123456789012345680000,1.5e-7,0.000001,0,null,100,1,5e-324]");
        for bad in ["01", "1.", "+1", "[1,]", "{a:1}", "\"\t\"", "\u{feff}1", "", "nul", "\"\\x\"", "1 2"] { assert!(parse(bad).is_none(), "{bad}"); }
        assert!(parse(&"[".repeat(100_000)).is_none());
        assert_eq!(Text::from("a😀").units(), 3);
    }
}
