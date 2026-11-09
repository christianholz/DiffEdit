use crate::{diff, repository};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub path: String,
    pub text: String,
    pub base: String,
    pub base_exists: bool,
    pub head: Option<String>,
    pub disk: Option<String>,
    pub version: u64,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Inspection {
    pub base: String,
    pub base_exists: bool,
    pub head: Option<String>,
    pub disk: Option<String>,
    pub version: u64,
    pub diff: Option<diff::DiffResult>,
}
#[derive(Serialize)]
pub struct Resolved {
    pub document: Document,
    pub diff: diff::DiffResult,
}
#[derive(Serialize)]
pub struct Saved {
    pub disk: Option<String>,
}
#[derive(Deserialize)]
pub struct Edit {
    pub from: usize,
    pub to: usize,
    pub insert: String,
}
#[derive(Serialize)]
pub struct Update {
    pub version: u64,
    pub head: Option<String>,
    pub diff: diff::DiffResult,
}
pub struct DiffInput {
    version: u64,
    head: Option<String>,
    base: String,
    text: String,
}
impl DiffInput {
    pub fn update(self) -> Update {
        Update {
            version: self.version,
            head: self.head,
            diff: diff::compute(&self.base, &self.text),
        }
    }
}
#[derive(Clone, Copy, Default, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ReviewSource {
    #[default]
    Buffer,
    Index,
}
#[derive(Deserialize)]
pub struct Selection {
    #[serde(default)]
    pub source: ReviewSource,
    pub path: String,
    pub version: u64,
    pub head: Option<String>,
    pub selected: HashSet<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StageSnapshot {
    pub source: ReviewSource,
    pub version: u64,
    pub head: Option<String>,
    pub index: String,
    pub rows: Vec<diff::StageRow>,
    pub selected: HashSet<String>,
}
impl Document {
    pub fn open(repo: &repository::Repo, path: String) -> Result<Self, String> {
        let disk = repository::disk(repo, &path)?;
        let base = repository::base_entry(repo, &path)?;
        Ok(Self {
            text: disk.clone().unwrap_or_default(),
            base_exists: base.is_some(),
            base: base.unwrap_or_default(),
            head: repo.head.clone(),
            disk,
            path,
            version: 0,
        })
    }
    pub fn diff_input(&self) -> DiffInput {
        DiffInput {
            version: self.version,
            head: self.head.clone(),
            base: self.base.clone(),
            text: self.text.clone(),
        }
    }
    pub fn edit(&mut self, version: u64, edits: &[Edit]) -> Result<(), String> {
        if version != self.version + 1 {
            return Err("Document version mismatch".into());
        }
        // Translate all sorted UTF-16 positions in one pass, then build once.
        let mut cursor = self.text.char_indices();
        let (mut units, mut byte) = (0, 0);
        let mut result = String::with_capacity(self.text.len());
        let mut previous = 0;
        let mut byte_at = |position| -> Result<usize, String> {
            if position < units {
                return Err("Overlapping or unsorted edits".into());
            }
            while units < position {
                let (i, ch) = cursor.next().ok_or("Position outside document")?;
                units += ch.len_utf16();
                byte = i + ch.len_utf8();
            }
            if units != position {
                return Err("Position splits a Unicode character".into());
            }
            Ok(byte)
        };
        for edit in edits {
            if edit.to < edit.from {
                return Err("Invalid edit".into());
            }
            let from = byte_at(edit.from)?;
            let to = byte_at(edit.to)?;
            result.push_str(&self.text[previous..from]);
            result.push_str(&edit.insert);
            previous = to;
        }
        result.push_str(&self.text[previous..]);
        self.text = result;
        self.version = version;
        Ok(())
    }
    pub fn exists(&self) -> bool {
        self.disk.is_some() || !self.text.is_empty()
    }
    pub fn rows(&self) -> Vec<diff::StageRow> {
        review_rows(&self.base, self.base_exists, &self.text, self.exists())
    }
    pub fn selected_text(&self, selection: &Selection) -> Result<Option<String>, String> {
        self.check_selection(selection)?;
        materialize(
            &self.base,
            self.base_exists,
            &self.text,
            self.exists(),
            &selection.selected,
        )
    }
    fn check_selection(&self, selection: &Selection) -> Result<(), String> {
        if selection.version != self.version || selection.head != self.head {
            return Err("Document changed; review the selection again".into());
        }
        Ok(())
    }
    pub fn selected_entry(
        &self,
        repo: &repository::Repo,
        selection: &Selection,
    ) -> Result<Option<String>, String> {
        self.check_selection(selection)?;
        match selection.source {
            ReviewSource::Buffer => self.selected_text(selection),
            ReviewSource::Index => {
                let staged = repository::index_text(repo, &self.path)?;
                materialize(
                    &self.base,
                    self.base_exists,
                    staged.as_deref().unwrap_or_default(),
                    staged.is_some(),
                    &selection.selected,
                )
            }
        }
    }
    #[cfg(test)]
    pub fn stage_snapshot(&self, repo: &repository::Repo) -> Result<StageSnapshot, String> {
        self.review(repo, None)
    }
    pub fn review(
        &self,
        repo: &repository::Repo,
        requested: Option<ReviewSource>,
    ) -> Result<StageSnapshot, String> {
        let g = repo.git_root.as_ref().ok_or("Not a Git repository")?;
        let index = repository::index_signature(g)?;
        repository::verify(repo, &index)?;
        if self.head != repo.head {
            return Err("HEAD changed; refresh the document before staging".into());
        }
        repository::validate_file_mode(repo, &self.path)?;
        let staged = repository::index_text(repo, &self.path)?;
        let staged_rows = review_rows(
            &self.base,
            self.base_exists,
            staged.as_deref().unwrap_or_default(),
            staged.is_some(),
        );
        let staged_ids: HashSet<_> = staged_rows.iter().filter_map(|r| r.id.clone()).collect();
        let buffer_rows = self.rows();
        let matching: HashSet<_> = buffer_rows
            .iter()
            .filter_map(|r| r.id.as_ref())
            .filter(|id| staged_ids.contains(*id))
            .cloned()
            .collect();
        let represented = materialize(
            &self.base,
            self.base_exists,
            &self.text,
            self.exists(),
            &matching,
        )? == staged;
        let source = requested.unwrap_or(if represented {
            ReviewSource::Buffer
        } else {
            ReviewSource::Index
        });
        let (rows, selected) = match source {
            ReviewSource::Buffer => (
                buffer_rows,
                if represented {
                    matching
                } else {
                    HashSet::new()
                },
            ),
            ReviewSource::Index => (staged_rows, staged_ids),
        };
        if repository::index_signature(g)? != index {
            return Err("Git staging changed during review; try again".into());
        }
        Ok(StageSnapshot {
            version: self.version,
            head: self.head.clone(),
            index,
            rows,
            selected,
            source,
        })
    }
}
fn review_rows(base: &str, base_exists: bool, text: &str, exists: bool) -> Vec<diff::StageRow> {
    let mut rows = diff::stage_rows(base, text);
    if base.is_empty() && text.is_empty() && base_exists != exists {
        rows.push(diff::StageRow {
            id: Some(if exists { "file:add" } else { "file:delete" }.into()),
            kind: if exists { "insert" } else { "delete" }.into(),
            text: String::new(),
            old_line: None,
            new_line: None,
        });
    }
    rows
}
fn materialize(
    base: &str,
    base_exists: bool,
    text: &str,
    exists: bool,
    selected: &HashSet<String>,
) -> Result<Option<String>, String> {
    let rows = review_rows(base, base_exists, text, exists);
    let available: HashSet<_> = rows.iter().filter_map(|r| r.id.clone()).collect();
    if !selected.is_subset(&available) {
        return Err("Changes updated; review the selection again".into());
    }
    let result = diff::staged_text(&rows, selected);
    let exists = if !available.is_empty() && selected == &available {
        exists
    } else if selected.is_empty() {
        base_exists
    } else {
        !result.is_empty() || base_exists
    };
    Ok(exists.then_some(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn doc() -> Document {
        Document {
            path: "a".into(),
            text: "a🦀bc".into(),
            base: "a🦀bc".into(),
            base_exists: true,
            head: Some("h".into()),
            disk: Some("a🦀bc".into()),
            version: 0,
        }
    }
    #[test]
    fn edits_are_atomic_sorted_and_utf16_aware() {
        let mut d = doc();
        d.edit(
            1,
            &[
                Edit {
                    from: 1,
                    to: 3,
                    insert: "🐝".into(),
                },
                Edit {
                    from: 4,
                    to: 5,
                    insert: "!".into(),
                },
            ],
        )
        .unwrap();
        assert_eq!(d.text, "a🐝b!");
        let snapshot = d.text.clone();
        assert!(d
            .edit(
                2,
                &[Edit {
                    from: 2,
                    to: 3,
                    insert: "x".into()
                }]
            )
            .is_err());
        assert_eq!(d.text, snapshot);
        assert_eq!(d.version, 1);
        assert!(d
            .edit(
                2,
                &[
                    Edit {
                        from: 3,
                        to: 4,
                        insert: "x".into()
                    },
                    Edit {
                        from: 1,
                        to: 2,
                        insert: "y".into()
                    }
                ]
            )
            .is_err());
        assert_eq!(d.text, snapshot);
    }
    #[test]
    fn existence_is_independent_of_empty_text_and_selection_is_validated() {
        let mut d = doc();
        d.base = String::new();
        d.text = String::new();
        d.disk = None;
        let choose = |d: &Document, ids: &[&str]| Selection {
            source: ReviewSource::Buffer,
            path: d.path.clone(),
            version: d.version,
            head: d.head.clone(),
            selected: ids.iter().map(|s| s.to_string()).collect(),
        };
        assert_eq!(
            d.selected_text(&choose(&d, &["file:delete"])).unwrap(),
            None
        );
        assert_eq!(
            d.selected_text(&choose(&d, &[])).unwrap(),
            Some(String::new())
        );
        d.base_exists = false;
        d.disk = Some(String::new());
        assert_eq!(
            d.selected_text(&choose(&d, &["file:add"])).unwrap(),
            Some(String::new())
        );
        assert_eq!(d.selected_text(&choose(&d, &[])).unwrap(), None);
        assert!(d.selected_text(&choose(&d, &["invalid"])).is_err());
        let mut stale = choose(&d, &[]);
        stale.head = None;
        assert!(d.selected_text(&stale).is_err());
    }
}
