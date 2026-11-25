//! Minimal JSON reader for engine requests: objects, arrays, strings, booleans, null and integers
//! (fractions and exponents are refused: every engine input is a fixed-point integer).
//! Nesting is limited to 8 levels and integers to i64 (checked arithmetic).

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(pairs) => pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

const MAX_DEPTH: usize = 8;

pub fn parse(input: &str) -> Result<Json, String> {
    let mut p = Parser { s: input.as_bytes(), i: 0, depth: 0 };
    p.ws();
    let value = p.value()?;
    p.ws();
    if p.i != p.s.len() {
        return Err("trailing characters".into());
    }
    Ok(value)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
    depth: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }

    fn expect(&mut self, c: u8) -> Result<(), String> {
        if self.peek() == Some(c) {
            self.i += 1;
            Ok(())
        } else {
            Err(format!("expected '{}'", c as char))
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Ok(Json::Str(self.string()?)),
            Some(b't') => self.literal("true", Json::Bool(true)),
            Some(b'f') => self.literal("false", Json::Bool(false)),
            Some(b'n') => self.literal("null", Json::Null),
            Some(c) if c == b'-' || c.is_ascii_digit() => self.integer(),
            _ => Err("unexpected character".into()),
        }
    }

    fn nest(&mut self) -> Result<(), String> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            Err("nesting too deep".into())
        } else {
            Ok(())
        }
    }

    fn object(&mut self) -> Result<Json, String> {
        self.nest()?;
        self.expect(b'{')?;
        let mut pairs = Vec::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
        } else {
            loop {
                self.ws();
                let key = self.string()?;
                self.ws();
                self.expect(b':')?;
                self.ws();
                let value = self.value()?;
                pairs.push((key, value));
                self.ws();
                match self.peek() {
                    Some(b',') => self.i += 1,
                    Some(b'}') => {
                        self.i += 1;
                        break;
                    }
                    _ => return Err("expected ',' or '}'".into()),
                }
            }
        }
        self.depth -= 1;
        Ok(Json::Obj(pairs))
    }

    fn array(&mut self) -> Result<Json, String> {
        self.nest()?;
        self.expect(b'[')?;
        let mut items = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
        } else {
            loop {
                self.ws();
                items.push(self.value()?);
                self.ws();
                match self.peek() {
                    Some(b',') => self.i += 1,
                    Some(b']') => {
                        self.i += 1;
                        break;
                    }
                    _ => return Err("expected ',' or ']'".into()),
                }
            }
        }
        self.depth -= 1;
        Ok(Json::Arr(items))
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            match self.peek() {
                None => return Err("unterminated string".into()),
                Some(b'"') => {
                    self.i += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.i += 1;
                    let c = self.peek().ok_or("unterminated escape")?;
                    self.i += 1;
                    match c {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let hex = self.s.get(self.i..self.i + 4).ok_or("short \\u escape")?;
                            let hex = std::str::from_utf8(hex).map_err(|_| "bad \\u escape")?;
                            let code = u32::from_str_radix(hex, 16).map_err(|_| "bad \\u escape")?;
                            out.push(char::from_u32(code).ok_or("unsupported \\u escape")?);
                            self.i += 4;
                        }
                        _ => return Err("bad escape".into()),
                    }
                }
                Some(c) if c < 0x20 => return Err("control character in string".into()),
                Some(_) => {
                    // copy one UTF-8 character
                    let rest = std::str::from_utf8(&self.s[self.i..]).map_err(|_| "invalid UTF-8")?;
                    let ch = rest.chars().next().ok_or("unterminated string")?;
                    out.push(ch);
                    self.i += ch.len_utf8();
                }
            }
        }
    }

    fn literal(&mut self, word: &str, value: Json) -> Result<Json, String> {
        if self.s[self.i..].starts_with(word.as_bytes()) {
            self.i += word.len();
            Ok(value)
        } else {
            Err("unexpected literal".into())
        }
    }

    fn integer(&mut self) -> Result<Json, String> {
        let negative = self.peek() == Some(b'-');
        if negative {
            self.i += 1;
        }
        let start = self.i;
        let mut n: i64 = 0;
        while let Some(c) = self.peek().filter(u8::is_ascii_digit) {
            n = n
                .checked_mul(10)
                .and_then(|n| n.checked_add((c - b'0') as i64))
                .ok_or("integer overflow")?;
            self.i += 1;
        }
        if self.i == start {
            return Err("expected digits".into());
        }
        if matches!(self.peek(), Some(b'.' | b'e' | b'E')) {
            return Err("integers only".into());
        }
        Ok(Json::Int(if negative { -n } else { n }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_objects_arrays_and_integers() {
        let v = parse(r#" {"model":"orbit","steps":10,"list":[1,-2,[3]],"ok":true,"none":null} "#).unwrap();
        assert_eq!(v.get("model"), Some(&Json::Str("orbit".into())));
        assert_eq!(v.get("steps"), Some(&Json::Int(10)));
        assert_eq!(
            v.get("list"),
            Some(&Json::Arr(vec![Json::Int(1), Json::Int(-2), Json::Arr(vec![Json::Int(3)])]))
        );
        assert_eq!(v.get("ok"), Some(&Json::Bool(true)));
        assert_eq!(v.get("none"), Some(&Json::Null));
    }

    #[test]
    fn refuses_floats_overflow_depth_and_garbage() {
        assert!(parse("1.5").is_err());
        assert!(parse("1e3").is_err());
        assert!(parse("99999999999999999999").is_err());
        assert!(parse("[[[[[[[[[1]]]]]]]]]").is_err());
        assert!(parse("{\"a\":1} x").is_err());
        assert!(parse("{\"a\" 1}").is_err());
        assert!(parse("\"unterminated").is_err());
    }
}
