use crate::{
    document::{Document, Selection},
    repository,
};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let p = std::env::temp_dir().join(format!(
            "diffedit-regression-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&p).unwrap();
        let f = Self(p);
        f.git(&["init", "-q"]);
        f.git(&["config", "user.name", "Test"]);
        f.git(&["config", "user.email", "test@example.invalid"]);
        f
    }
    fn root(&self) -> &str {
        self.0.to_str().unwrap()
    }
    fn git(&self, args: &[&str]) -> String {
        String::from_utf8(repository::git(self.root(), args, None).unwrap()).unwrap()
    }
    fn write(&self, path: &str, text: &str) {
        if let Some(parent) = self.0.join(path).parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(self.0.join(path), text).unwrap();
    }
    fn commit(&self) {
        self.git(&["add", "."]);
        self.git(&["commit", "-qm", "fixture"]);
    }
    fn repo(&self) -> repository::Repo {
        repository::discover(self.root()).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn all(d: &Document) -> Selection {
    Selection {
        path: d.path.clone(),
        version: d.version,
        head: d.head.clone(),
        selected: d.rows().iter().filter_map(|r| r.id.clone()).collect(),
    }
}

#[test]
fn deletions_empty_files_and_missing_directories_survive_review_and_staging() {
    let f = Fixture::new();
    f.write("gone/a", "old\n");
    f.write("empty", "");
    f.commit();
    fs::remove_dir_all(f.0.join("gone")).unwrap();
    fs::remove_file(f.0.join("empty")).unwrap();
    f.write("new-empty", "");
    let r = f.repo();
    let mut entries = Vec::new();
    for path in ["gone/a", "empty", "new-empty"] {
        let d = Document::open(&r, path.into()).unwrap();
        entries.push((path.into(), d.selected_text(&all(&d)).unwrap()));
    }
    repository::apply_selection(&r, &r.index, &entries, None).unwrap();
    assert_eq!(
        f.git(&["diff", "--no-renames", "--cached", "--name-status"]),
        "D\tempty\nD\tgone/a\nA\tnew-empty\n"
    );
    let r = f.repo();
    assert!(r.files.contains(&"gone/a".into()));
    assert!(r.files.contains(&"empty".into()));
    repository::save(&r, "gone/a", "restored", &None).unwrap();
    assert_eq!(fs::read_to_string(f.0.join("gone/a")).unwrap(), "restored");
}
#[test]
fn selected_commit_is_multi_file_and_preserves_unsaved_work() {
    let f = Fixture::new();
    f.write("a", "old first\nanchor\nold second\n");
    f.write("b", "before\n");
    f.commit();
    let r = f.repo();
    let mut a = Document::open(&r, "a".into()).unwrap();
    a.text = "new first\nanchor\nnew second\n".into();
    let chosen: std::collections::HashSet<_> = a
        .rows()
        .iter()
        .filter(|row| row.old_line == Some(1) || row.new_line == Some(1))
        .filter_map(|r| r.id.clone())
        .collect();
    let mut selection = all(&a);
    selection.selected = chosen;
    let mut b = Document::open(&r, "b".into()).unwrap();
    b.text = "after\n".into();
    let entries = vec![
        ("a".into(), a.selected_text(&selection).unwrap()),
        ("b".into(), b.selected_text(&all(&b)).unwrap()),
    ];
    repository::apply_selection(&r, &r.index, &entries, Some("selected")).unwrap();
    assert_eq!(
        f.git(&["show", "HEAD:a"]),
        "new first\nanchor\nold second\n"
    );
    assert_eq!(f.git(&["show", "HEAD:b"]), "after\n");
    assert_eq!(
        fs::read_to_string(f.0.join("a")).unwrap(),
        "old first\nanchor\nold second\n"
    );
    assert_eq!(f.git(&["diff", "--cached", "--name-only"]), "");
}
#[test]
fn existing_partial_index_is_reflected_and_unrepresentable_content_is_rejected() {
    let f = Fixture::new();
    f.write("a", "old\nanchor\nold\n");
    f.commit();
    f.write("a", "staged\nanchor\nold\n");
    f.git(&["add", "a"]);
    f.write("a", "staged\nanchor\nworking\n");
    let r = f.repo();
    let d = Document::open(&r, "a".into()).unwrap();
    let snapshot = d.stage_snapshot(&r).unwrap();
    let selection = Selection {
        path: d.path.clone(),
        version: d.version,
        head: d.head.clone(),
        selected: snapshot.selected,
    };
    assert_eq!(
        d.selected_text(&selection).unwrap(),
        Some("staged\nanchor\nold\n".into())
    );
    f.write("a", "different\n");
    let d = Document::open(&r, "a".into()).unwrap();
    assert!(d.stage_snapshot(&r).is_err());
}
#[test]
fn failed_hook_preserves_index_head_and_working_files() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    f.write("a", "old\n");
    f.commit();
    f.write("a", "already staged\n");
    f.git(&["add", "a"]);
    let r = f.repo();
    let head = f.git(&["rev-parse", "HEAD"]);
    let index = fs::read(f.0.join(".git/index")).unwrap();
    let hook = f.0.join(".git/hooks/pre-commit");
    fs::write(&hook, "#!/bin/sh\nexit 1\n").unwrap();
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(repository::apply_selection(
        &r,
        &r.index,
        &[("a".into(), Some("candidate\n".into()))],
        Some("fails")
    )
    .is_err());
    assert_eq!(fs::read(f.0.join(".git/index")).unwrap(), index);
    assert_eq!(f.git(&["rev-parse", "HEAD"]), head);
    assert_eq!(f.git(&["show", ":a"]), "already staged\n");
    assert!(!f.0.join(".git/index.lock").exists());
}
#[test]
fn stale_head_index_and_unreviewed_staged_files_are_rejected_without_mutation() {
    let f = Fixture::new();
    f.write("a", "old\n");
    f.write("outside", "old\n");
    f.commit();
    let stale = f.repo();
    f.write("a", "external\n");
    f.git(&["add", "a"]);
    assert!(repository::apply_selection(&stale, &stale.index, &[], None).is_err());
    f.git(&["commit", "-qm", "external"]);
    assert!(repository::apply_selection(&stale, &stale.index, &[], None).is_err());
    f.write("outside", "staged\n");
    f.git(&["add", "outside"]);
    let r = f.repo();
    let before = f.git(&["write-tree"]);
    assert!(repository::apply_selection(
        &r,
        &r.index,
        &[("a".into(), Some("candidate\n".into()))],
        Some("blocked")
    )
    .is_err());
    assert_eq!(f.git(&["write-tree"]), before);
}
#[test]
fn symlinks_and_outside_paths_are_rejected() {
    let f = Fixture::new();
    f.write("target", "contents\n");
    std::os::unix::fs::symlink("target", f.0.join("link")).unwrap();
    f.commit();
    let r = f.repo();
    assert!(Document::open(&r, "link".into()).is_err());
    assert!(repository::apply_selection(
        &r,
        &r.index,
        &[("link".into(), Some("contents\n".into()))],
        None
    )
    .is_err());
    assert_eq!(f.git(&["show", ":link"]), "target");
    assert!(repository::path(&r, "../escape").is_err());
}
#[test]
fn git_blob_reads_literal_newlines_and_missing_files() {
    let f = Fixture::new();
    f.write("a\nfile", "contents\n");
    f.commit();
    let r = f.repo();
    assert_eq!(repository::base(&r, "a\nfile").unwrap(), "contents\n");
    assert_eq!(repository::base(&r, "missing").unwrap(), "");
}
#[test]
fn initial_commit_can_include_a_new_empty_file() {
    let f = Fixture::new();
    f.write("empty", "");
    let r = f.repo();
    let d = Document::open(&r, "empty".into()).unwrap();
    repository::apply_selection(
        &r,
        &r.index,
        &[("empty".into(), d.selected_text(&all(&d)).unwrap())],
        Some("initial"),
    )
    .unwrap();
    assert_eq!(f.git(&["ls-tree", "--name-only", "HEAD"]), "empty\n");
}

#[test]
fn permission_changes_are_rejected_instead_of_silently_included() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    f.write("a", "text\n");
    f.commit();
    fs::set_permissions(f.0.join("a"), fs::Permissions::from_mode(0o755)).unwrap();
    let r = f.repo();
    let d = Document::open(&r, "a".into()).unwrap();
    assert!(d.stage_snapshot(&r).err().unwrap().contains("permissions"));
}
#[test]
fn save_does_not_silently_break_hard_links() {
    let f = Fixture::new();
    f.write("a", "old");
    fs::hard_link(f.0.join("a"), f.0.join("b")).unwrap();
    let r = f.repo();
    assert!(repository::save(&r, "a", "new", &Some("old".into())).is_err());
    assert_eq!(fs::read_to_string(f.0.join("b")).unwrap(), "old");
}
#[cfg(target_os = "macos")]
#[test]
fn atomic_save_preserves_extended_attributes() {
    let f = Fixture::new();
    f.write("a", "old");
    let path = f.0.join("a");
    assert!(std::process::Command::new("/usr/bin/xattr")
        .args(["-w", "com.diffedit.test", "preserved"])
        .arg(&path)
        .status()
        .unwrap()
        .success());
    let r = f.repo();
    repository::save(&r, "a", "new", &Some("old".into())).unwrap();
    let out = std::process::Command::new("/usr/bin/xattr")
        .args(["-p", "com.diffedit.test"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(String::from_utf8(out.stdout).unwrap().trim(), "preserved");
}

#[test]
fn switching_branches_at_the_same_commit_invalidates_review() {
    let f = Fixture::new();
    f.write("a", "old\n");
    f.commit();
    let r = f.repo();
    f.git(&["checkout", "-qb", "other"]);
    assert!(repository::apply_selection(
        &r,
        &r.index,
        &[("a".into(), Some("candidate\n".into()))],
        Some("wrong branch")
    )
    .is_err());
    assert_eq!(f.git(&["show", "HEAD:a"]), "old\n");
}
