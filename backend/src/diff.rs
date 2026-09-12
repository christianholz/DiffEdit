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
        v.push(v.last().unwrap() + t.encode_utf16().count());
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
    fn offsets(s: &str) -> Vec<usize> {
        let mut result = Vec::with_capacity(s.len() + 1);
        for (byte, ch) in s.char_indices() {
            for _ in 0..ch.len_utf16() {
                result.push(byte);
            }
        }
        result.push(s.len());
        result
    }
    let ax = offsets(a);
    let bx = offsets(b);
    let mut grouped: Vec<Change> = Vec::new();
    for c in changes {
        if let Some(last) = grouped.last_mut() {
            let ag = &a[ax[last.a_end]..ax[c.a]];
            let bg = &b[bx[last.b_end]..bx[c.b]];
            // Horizontal separators inside a consecutive rewrite belong to its group.
            // Keep punctuation, actual equal words and paragraph boundaries as anchors.
            let multiline = a[ax[last.a]..ax[c.a_end]].contains('\n')
                || b[bx[last.b]..bx[c.b_end]].contains('\n');
            if ag == bg && !multiline && ag.chars().all(|c| c == ' ' || c == '\t') {
                last.a_end = c.a_end;
                last.b_end = c.b_end;
                continue;
            }
        }
        grouped.push(c);
    }
    for c in &mut grouped {
        while c.a < c.a_end && c.b < c.b_end {
            let x = a[ax[c.a]..].chars().next().unwrap();
            let y = b[bx[c.b]..].chars().next().unwrap();
            if x != y || !x.is_whitespace() {
                break;
            }
            c.a += x.len_utf16();
            c.b += y.len_utf16();
        }
        while c.a < c.a_end && c.b < c.b_end {
            let x = a[..ax[c.a_end]].chars().next_back().unwrap();
            let y = b[..bx[c.b_end]].chars().next_back().unwrap();
            if x != y || !x.is_whitespace() {
                break;
            }
            c.a_end -= x.len_utf16();
            c.b_end -= y.len_utf16();
        }
    }
    grouped.retain(|c| c.a < c.a_end || c.b < c.b_end);
    grouped
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
    for (ar, br) in hunks(&at, &bt, Algorithm::Myers) {
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
                id: Some(format!("d:{i}:{}", at[i])),
                kind: "delete".into(),
                text: at[i].into(),
                old_line: Some(i + 1),
                new_line: None,
            });
        }
        for i in br.clone() {
            rows.push(StageRow {
                id: Some(format!("i:{i}:{}", bt[i])),
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
