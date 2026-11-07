use imara_diff::{Algorithm, Diff, InternedInput};
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Change {
    pub a: usize,
    pub a_end: usize,
    pub b: usize,
    pub b_end: usize,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffResult {
    pub changes: Vec<Change>,
    pub micros: u128,
}
fn hunks(
    a: &[&str],
    b: &[&str],
    algorithm: Algorithm,
) -> Vec<(std::ops::Range<usize>, std::ops::Range<usize>)> {
    let mut input = InternedInput::default();
    input.update_before(a.iter().copied());
    input.update_after(b.iter().copied());
    Diff::compute(algorithm, &input)
        .hunks()
        .map(|h| {
            (
                h.before.start as usize..h.before.end as usize,
                h.after.start as usize..h.after.end as usize,
            )
        })
        .collect()
}
fn offsets(tokens: &[&str]) -> Vec<usize> {
    let mut v = vec![0];
    for t in tokens {
        v.push(
            v.last().unwrap()
                + if t.is_ascii() {
                    t.len()
                } else {
                    t.encode_utf16().count()
                },
        );
    }
    v
}
fn category(s: &str) -> u8 {
    let c = s.chars().next().unwrap();
    if c == '\n' || c == '\r' {
        0
    } else if c.is_whitespace() {
        1
    } else if c.is_alphanumeric() || c == '_' {
        2
    } else {
        3
    }
}
fn tokens(s: &str) -> Vec<&str> {
    let mut result = Vec::new();
    let mut start = 0;
    let mut prev = 255;
    for (i, g) in s.grapheme_indices(true) {
        let kind = category(g);
        if i > start && (kind != prev || kind == 3 || kind == 0) {
            result.push(&s[start..i]);
            start = i;
        }
        prev = kind;
    }
    if start < s.len() {
        result.push(&s[start..]);
    }
    result
}
// Only refine spelling edits within an otherwise recognisable word. Arbitrary
// shared characters between unrelated words are not useful correspondence.
fn closely_related(a: &str, b: &str) -> bool {
    let x: Vec<_> = a.graphemes(true).collect();
    let y: Vec<_> = b.graphemes(true).collect();
    let prefix = x.iter().zip(&y).take_while(|(a, b)| a == b).count();
    let suffix = x[prefix..]
        .iter()
        .rev()
        .zip(y[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let shared = prefix + suffix;
    shared >= 3 && shared * 3 >= x.len().max(y.len()) * 2
}
fn group_phrases(changes: Vec<Change>, a: &str, b: &str) -> Vec<Change> {
    if changes.is_empty() {
        return changes;
    }
    // Store offsets only at change boundaries, rather than one usize per
    // UTF-16 unit of both documents. A sparse edit now uses sparse memory.
    fn positions(s: &str, mut wanted: Vec<usize>) -> Vec<(usize, usize)> {
        wanted.sort_unstable();
        wanted.dedup();
        if s.is_ascii() {
            return wanted.into_iter().map(|p| (p, p)).collect();
        }
        let mut found = Vec::with_capacity(wanted.len());
        let mut units = 0;
        let mut at = wanted.into_iter().peekable();
        for (byte, ch) in s.char_indices().chain(std::iter::once((s.len(), '\0'))) {
            if at.peek() == Some(&units) {
                found.push((units, byte));
                at.next();
            }
            if at.peek().is_none() {
                break;
            }
            units += ch.len_utf16();
        }
        found
    }
    let ax = positions(a, changes.iter().flat_map(|c| [c.a, c.a_end]).collect());
    let bx = positions(b, changes.iter().flat_map(|c| [c.b, c.b_end]).collect());
    let byte = |v: &Vec<(usize, usize)>, p| v[v.binary_search_by_key(&p, |(u, _)| *u).unwrap()].1;
    let mut grouped: Vec<(Change, usize, usize, usize, usize, bool)> = Vec::new();
    for c in changes {
        let (aa, ae, bb, be) = (
            byte(&ax, c.a),
            byte(&ax, c.a_end),
            byte(&bx, c.b),
            byte(&bx, c.b_end),
        );
        let multiline = a[aa..ae].contains('\n') || b[bb..be].contains('\n');
        if let Some((last, _, lae, _, lbe, last_multiline)) = grouped.last_mut() {
            let ag = &a[*lae..aa];
            let bg = &b[*lbe..bb];
            if !*last_multiline
                && !multiline
                && ag == bg
                && ag.chars().all(|c| c == ' ' || c == '\t')
            {
                last.a_end = c.a_end;
                last.b_end = c.b_end;
                *lae = ae;
                *lbe = be;
                continue;
            }
        }
        grouped.push((c, aa, ae, bb, be, multiline));
    }
    let mut result = Vec::with_capacity(grouped.len());
    for (mut c, mut aa, mut ae, mut bb, mut be, _) in grouped {
        while aa < ae && bb < be {
            let x = a[aa..ae].chars().next().unwrap();
            let y = b[bb..be].chars().next().unwrap();
            if x != y || !x.is_whitespace() {
                break;
            }
            aa += x.len_utf8();
            bb += y.len_utf8();
            c.a += x.len_utf16();
            c.b += y.len_utf16();
        }
        while aa < ae && bb < be {
            let x = a[aa..ae].chars().next_back().unwrap();
            let y = b[bb..be].chars().next_back().unwrap();
            if x != y || !x.is_whitespace() {
                break;
            }
            ae -= x.len_utf8();
            be -= y.len_utf8();
            c.a_end -= x.len_utf16();
            c.b_end -= y.len_utf16();
        }
        if c.a < c.a_end || c.b < c.b_end {
            result.push(c);
        }
    }
    result
}
fn refine(a: &str, b: &str, ao: usize, bo: usize, out: &mut Vec<Change>, depth: u8) {
    let at: Vec<&str> = if depth == 0 {
        tokens(a)
    } else {
        a.graphemes(true).collect()
    };
    let bt: Vec<&str> = if depth == 0 {
        tokens(b)
    } else {
        b.graphemes(true).collect()
    };
    let ap = offsets(&at);
    let bp = offsets(&bt);
    let prefix = at.iter().zip(&bt).take_while(|(a, b)| a == b).count();
    let suffix = at[prefix..]
        .iter()
        .rev()
        .zip(bt[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let ae = at.len() - suffix;
    let be = bt.len() - suffix;
    if (ae - prefix).saturating_mul(be - prefix) > 4_000_000 {
        out.push(Change {
            a: ao + ap[prefix],
            a_end: ao + ap[ae],
            b: bo + bp[prefix],
            b_end: bo + bp[be],
        });
        return;
    }
    for (ar, br) in hunks(&at[prefix..ae], &bt[prefix..be], Algorithm::Myers) {
        let ar = ar.start + prefix..ar.end + prefix;
        let br = br.start + prefix..br.end + prefix;
        if depth == 0
            && !ar.is_empty()
            && !br.is_empty()
            && ar.len() == 1
            && br.len() == 1
            && a.len() + b.len() < 8192
            && closely_related(at[ar.start], bt[br.start])
        {
            let x = at[ar.clone()].concat();
            let y = bt[br.clone()].concat();
            refine(&x, &y, ao + ap[ar.start], bo + bp[br.start], out, 1);
        } else {
            out.push(Change {
                a: ao + ap[ar.start],
                a_end: ao + ap[ar.end],
                b: bo + bp[br.start],
                b_end: bo + bp[br.end],
            });
        }
    }
}
// Align related physical lines before refining words, so deleted equations cannot
// borrow punctuation or words from a later prose sentence.
fn refine_lines(a: &str, b: &str, ao: usize, bo: usize, out: &mut Vec<Change>) {
    if a.split_whitespace().eq(b.split_whitespace()) {
        refine(a, b, ao, bo, out, 0);
        return;
    }
    let al: Vec<_> = a.split_inclusive('\n').collect();
    let bl: Vec<_> = b.split_inclusive('\n').collect();
    if al.len() * bl.len() > 40000 {
        refine(a, b, ao, bo, out, 0);
        return;
    }
    let words = |line: &str| {
        line.split(|c: char| !c.is_alphanumeric())
            .filter(|s| !s.is_empty())
            .map(str::to_lowercase)
            .collect::<std::collections::HashSet<_>>()
    };
    let aw: Vec<_> = al.iter().map(|s| words(s)).collect();
    let bw: Vec<_> = bl.iter().map(|s| words(s)).collect();
    let n = al.len();
    let m = bl.len();
    let mut dp = vec![0.0f64; (n + 1) * (m + 1)];
    let mut scores = vec![0.0; n * m];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            let common = aw[i].intersection(&bw[j]).count();
            let score = if al[i] == bl[j] {
                2.0
            } else if common >= 2 {
                common as f64 / aw[i].len().max(bw[j].len()) as f64
            } else {
                0.0
            };
            scores[i * m + j] = if score >= 0.18 { score } else { 0.0 };
            dp[i * (m + 1) + j] = dp[(i + 1) * (m + 1) + j].max(dp[i * (m + 1) + j + 1]);
            if scores[i * m + j] > 0.0 {
                dp[i * (m + 1) + j] =
                    dp[i * (m + 1) + j].max(scores[i * m + j] + dp[(i + 1) * (m + 1) + j + 1]);
            }
        }
    }
    let ap = offsets(&al);
    let bp = offsets(&bl);
    let (mut i, mut j) = (0, 0);
    let (mut pi, mut pj) = (0, 0);
    while i < n && j < m {
        if scores[i * m + j] > 0.0
            && (dp[i * (m + 1) + j] - scores[i * m + j] - dp[(i + 1) * (m + 1) + j + 1]).abs()
                < 1e-9
        {
            if pi < i || pj < j {
                refine(
                    &al[pi..i].concat(),
                    &bl[pj..j].concat(),
                    ao + ap[pi],
                    bo + bp[pj],
                    out,
                    0,
                );
            }
            refine(al[i], bl[j], ao + ap[i], bo + bp[j], out, 0);
            i += 1;
            j += 1;
            pi = i;
            pj = j;
        } else if dp[(i + 1) * (m + 1) + j] >= dp[i * (m + 1) + j + 1] {
            i += 1;
        } else {
            j += 1;
        }
    }
    if pi < n || pj < m {
        refine(
            &al[pi..].concat(),
            &bl[pj..].concat(),
            ao + ap[pi],
            bo + bp[pj],
            out,
            0,
        );
    }
}
pub fn compute(a: &str, b: &str) -> DiffResult {
    let start = std::time::Instant::now();
    if a == b {
        return DiffResult {
            changes: Vec::new(),
            micros: start.elapsed().as_micros(),
        };
    }
    let at: Vec<&str> = a.split_inclusive('\n').collect();
    let bt: Vec<&str> = b.split_inclusive('\n').collect();
    let ap = offsets(&at);
    let bp = offsets(&bt);
    let mut changes = Vec::new();
    for (ar, br) in hunks(&at, &bt, Algorithm::Histogram) {
        if !ar.is_empty()
            && !br.is_empty()
            && ap[ar.end] - ap[ar.start] + bp[br.end] - bp[br.start] < 200_000
        {
            refine_lines(
                &at[ar.clone()].concat(),
                &bt[br.clone()].concat(),
                ap[ar.start],
                bp[br.start],
                &mut changes,
            );
        } else {
            changes.push(Change {
                a: ap[ar.start],
                a_end: ap[ar.end],
                b: bp[br.start],
                b_end: bp[br.end],
            });
        }
    }
    DiffResult {
        changes: group_phrases(changes, a, b),
        micros: start.elapsed().as_micros(),
    }
}
#[cfg(test)]
pub fn byte_at(s: &str, p: usize) -> Result<usize, String> {
    let mut n = 0;
    for (i, c) in s.char_indices() {
        if n == p {
            return Ok(i);
        }
        n += c.len_utf16();
        if n > p {
            return Err("Position splits a Unicode character".into());
        }
    }
    if n == p {
        Ok(s.len())
    } else {
        Err("Position outside document".into())
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StageRow {
    pub id: Option<String>,
    pub kind: String,
    pub text: String,
    pub old_line: Option<usize>,
    pub new_line: Option<usize>,
}
fn row_id(kind: char, index: usize, text: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hash);
    format!("{kind}:{index}:{:x}", hash.finish())
}
pub fn stage_rows(a: &str, b: &str) -> Vec<StageRow> {
    let at: Vec<&str> = a.split_inclusive('\n').collect();
    let bt: Vec<&str> = b.split_inclusive('\n').collect();
    let mut rows = Vec::new();
    let mut ai = 0;
    let mut bi = 0;
    for (ar, br) in hunks(&at, &bt, Algorithm::Histogram) {
        while ai < ar.start {
            rows.push(StageRow {
                id: None,
                kind: "equal".into(),
                text: at[ai].into(),
                old_line: Some(ai + 1),
                new_line: Some(bi + 1),
            });
            ai += 1;
            bi += 1;
        }
        for i in ar.clone() {
            rows.push(StageRow {
                id: Some(row_id('d', i, at[i])),
                kind: "delete".into(),
                text: at[i].into(),
                old_line: Some(i + 1),
                new_line: None,
            });
        }
        for i in br.clone() {
            rows.push(StageRow {
                id: Some(row_id('i', i, bt[i])),
                kind: "insert".into(),
                text: bt[i].into(),
                old_line: None,
                new_line: Some(i + 1),
            });
        }
        ai = ar.end;
        bi = br.end;
    }
    while ai < at.len() {
        rows.push(StageRow {
            id: None,
            kind: "equal".into(),
            text: at[ai].into(),
            old_line: Some(ai + 1),
            new_line: Some(bi + 1),
        });
        ai += 1;
        bi += 1;
    }
    rows
}
pub fn staged_text(rows: &[StageRow], selected: &std::collections::HashSet<String>) -> String {
    rows.iter()
        .filter(|r| match r.kind.as_str() {
            "equal" => true,
            "delete" => !selected.contains(r.id.as_ref().unwrap()),
            _ => selected.contains(r.id.as_ref().unwrap()),
        })
        .map(|r| r.text.as_str())
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_alignment_invariants() {
        let old = r"moved in \method's favour without a global effect";
        let new = "did not differ significantly across conditions";
        assert_eq!(
            compute(old, new).changes,
            vec![Change {
                a: 0,
                a_end: old.len(),
                b: 0,
                b_end: new.len()
            }]
        );
        let sentence = "long pause on budget is decision weight";
        let revised = "long pause on budget can reflect decision weight";
        let d = compute(sentence, revised);
        assert_eq!(d.changes.len(), 1);
        let c = &d.changes[0];
        assert_eq!(&revised[c.b..c.b_end], "can reflect");
        assert_eq!(&sentence[c.a..c.a_end], "is");
        let before = "Estimator:\nmath . more math\nend";
        let after = "Estimator.";
        assert!(!compute(before, after).changes.is_empty());
        let cases = [
            ("or the album did, and", "or album, and"),
            ("conditions});", "conditions})."),
            ("CowPilot", "CoPilot"),
            ("a sentence. Next", "a sentence.\nNext"),
            (" a ", " the "),
            ("a\t b\n\n\n", "a    b\n\n"),
            ("hello 🦀 café", "hello 🐝 café"),
            ("", "insert"),
            ("delete", ""),
            ("same", "same"),
        ];
        for (a, b) in cases {
            let d = compute(a, b);
            assert_eq!(d.changes, compute(a, b).changes);
            let (mut x, mut y) = (0, 0);
            let mut rebuilt = String::new();
            for c in &d.changes {
                let (ax, ae, bx, be) = (
                    byte_at(a, c.a).unwrap(),
                    byte_at(a, c.a_end).unwrap(),
                    byte_at(b, c.b).unwrap(),
                    byte_at(b, c.b_end).unwrap(),
                );
                assert_eq!(&a[x..ax], &b[y..bx]);
                rebuilt.push_str(&a[x..ax]);
                rebuilt.push_str(&b[bx..be]);
                x = ae;
                y = be;
            }
            assert_eq!(&a[x..], &b[y..]);
            rebuilt.push_str(&a[x..]);
            assert_eq!(rebuilt, b);
        }
        assert_eq!(
            compute("conditions});", "conditions}).").changes,
            vec![Change {
                a: 12,
                a_end: 13,
                b: 12,
                b_end: 13
            }]
        );
        let d = compute("or the album did, and", "or album, and");
        assert!(d.changes.iter().all(|c| !"or album, and"
            [byte_at("or album, and", c.b).unwrap()..byte_at("or album, and", c.b_end).unwrap()]
            .contains(',')));
    }
    #[test]
    fn partial_staging() {
        let r = stage_rows("old\nkeep\n", "new\nkeep\n");
        let all = r.iter().filter_map(|r| r.id.clone()).collect();
        assert_eq!(staged_text(&r, &all), "new\nkeep\n");
        assert_eq!(staged_text(&r, &Default::default()), "old\nkeep\n");
    }
}

pub fn benchmark(paths: &[String]) -> Result<(), String> {
    let (a, b) = if paths.len() >= 2 {
        (
            std::fs::read_to_string(&paths[0]).map_err(|e| e.to_string())?,
            std::fs::read_to_string(&paths[1]).map_err(|e| e.to_string())?,
        )
    } else {
        let a=(0..800).map(|i|format!("\\paragraph{{Observation {i}}} We compared three presentations of one visit within subjects (Table~\\ref{{tab:conditions}}). The photo album showed the photographs the visitor had taken during the visit, in order, on a laptop. Everything derives from the visitor's record.\n\n")).collect::<String>();
        let b = a
            .replace("within subjects", "using a within-subjects design")
            .replace(
                "in order, on a laptop",
                "in chronological order on a laptop",
            );
        (a, b)
    };
    if paths.get(2).map(String::as_str) == Some("--changes") {
        println!(
            "{}",
            serde_json::to_string(&compute(&a, &b)).map_err(|e| e.to_string())?
        );
        return Ok(());
    }
    let mut times = Vec::new();
    let mut count = 0;
    for _ in 0..30 {
        let d = compute(&a, &b);
        times.push(d.micros);
        count = d.changes.len();
    }
    times.sort();
    println!(
        "bytes={} changes={} median_ms={:.3} p95_ms={:.3}",
        b.len(),
        count,
        times[15] as f64 / 1000.,
        times[28] as f64 / 1000.
    );
    let mut sparse_times = Vec::new();
    let mut sparse = a.clone();
    for _ in 0..30 {
        sparse.push('x');
        sparse_times.push(compute(&a, &sparse).micros);
    }
    sparse_times.sort();
    println!(
        "single-edit native recomputation: median_ms={:.3} p95_ms={:.3}",
        sparse_times[15] as f64 / 1000.,
        sparse_times[28] as f64 / 1000.
    );
    let mut incremental = b.clone();
    let mut times = Vec::new();
    for _ in 0..30 {
        incremental.push('x');
        times.push(compute(&a, &incremental).micros);
    }
    times.sort();
    println!(
        "full native recomputation while typing: median_ms={:.3} p95_ms={:.3}",
        times[15] as f64 / 1000.,
        times[28] as f64 / 1000.
    );
    Ok(())
}

#[cfg(test)]
mod regression_tests {
    use super::*;
    fn aligned(a: &str, b: &str) {
        let d = compute(a, b);
        let (mut x, mut y) = (0, 0);
        let mut rebuilt = String::new();
        for c in d.changes {
            let (aa, ae, bb, be) = (
                byte_at(a, c.a).unwrap(),
                byte_at(a, c.a_end).unwrap(),
                byte_at(b, c.b).unwrap(),
                byte_at(b, c.b_end).unwrap(),
            );
            assert!(aa >= x && bb >= y && ae >= aa && be >= bb);
            assert_eq!(&a[x..aa], &b[y..bb]);
            rebuilt.push_str(&a[x..aa]);
            rebuilt.push_str(&b[bb..be]);
            x = ae;
            y = be;
        }
        assert_eq!(&a[x..], &b[y..]);
        rebuilt.push_str(&a[x..]);
        assert_eq!(rebuilt, b);
    }
    #[test]
    fn unicode_random_edits_and_bounded_large_rewrites_preserve_alignment() {
        let mut seed = 7u32;
        let mut rand = |n: usize| {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            seed as usize % n
        };
        let alphabet = ["a", "word", " ", "\n", "🦀", "é", "𐐀", ".", "\t"];
        for _ in 0..1000 {
            let a = (0..rand(80))
                .map(|_| alphabet[rand(alphabet.len())])
                .collect::<String>();
            let mut chars: Vec<_> = a.chars().collect();
            let from = rand(chars.len() + 1);
            let to = from + rand(chars.len() - from + 1);
            chars.splice(from..to, alphabet[rand(alphabet.len())].chars());
            let b = chars.into_iter().collect::<String>();
            aligned(&a, &b);
        }
        let a = (0..3000).map(|i| format!("before{i} ")).collect::<String>();
        let b = (0..3000).map(|i| format!("after{i} ")).collect::<String>();
        aligned(&a, &b);
    }
}
