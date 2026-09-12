use serde::Serialize;
use std::{
    collections::{BTreeSet, HashSet},
    fs,
    io::Write,
    path::{Component, Path, PathBuf},
    process::{Command, Stdio},
};
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Repo {
    pub root: String,
    pub git_root: Option<String>,
    pub prefix: String,
    pub branch: String,
    pub files: Vec<String>,
    pub changed: Vec<String>,
    pub staged: Vec<String>,
}
pub fn git(root: &str, args: &[&str], input: Option<&[u8]>) -> Result<Vec<u8>, String> {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let writer = input.map(|data| {
        let bytes = data.to_vec();
        let mut stdin = child.stdin.take().unwrap();
        std::thread::spawn(move || stdin.write_all(&bytes))
    });
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if let Some(w) = writer {
        w.join()
            .map_err(|_| "Git input failed")?
            .map_err(|e| e.to_string())?;
    }
    if out.status.success() {
        Ok(out.stdout)
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().into())
    }
}
fn strings(v: Vec<u8>) -> Vec<String> {
    v.split(|x| *x == 0)
        .filter(|x| !x.is_empty())
        .map(|x| String::from_utf8_lossy(x).into())
        .collect()
}
fn walk(root: &Path, at: &Path, out: &mut BTreeSet<String>) {
    if let Ok(entries) = fs::read_dir(at) {
        for e in entries.flatten() {
            let p = e.path();
            if e.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            if let Ok(t) = e.file_type() {
                if t.is_dir() {
                    walk(root, &p, out)
                } else if t.is_file() {
                    if let Ok(r) = p.strip_prefix(root) {
                        out.insert(r.to_string_lossy().into());
                    }
                }
            }
        }
    }
}
pub fn discover(root: &str) -> Result<Repo, String> {
    let root = fs::canonicalize(root)
        .map_err(|e| e.to_string())?
        .to_string_lossy()
        .to_string();
    let git_root = git(&root, &["rev-parse", "--show-toplevel"], None)
        .ok()
        .map(|v| String::from_utf8_lossy(&v).trim().to_string());
    let mut r = Repo {
        root: root.clone(),
        git_root: git_root.clone(),
        prefix: String::new(),
        branch: String::new(),
        files: vec![],
        changed: vec![],
        staged: vec![],
    };
    let mut files = BTreeSet::new();
    if let Some(g) = git_root {
        r.prefix = Path::new(&root)
            .strip_prefix(&g)
            .map_err(|e| e.to_string())?
            .to_string_lossy()
            .into();
        r.branch = git(&g, &["symbolic-ref", "--quiet", "--short", "HEAD"], None)
            .ok()
            .map(|v| String::from_utf8_lossy(&v).trim().into())
            .unwrap_or("HEAD".into());
        let ui = |p: String| -> Option<String> {
            if r.prefix.is_empty() {
                Some(p)
            } else {
                p.strip_prefix(&(r.prefix.clone() + "/")).map(String::from)
            }
        };
        for p in strings(git(
            &g,
            &[
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ],
            None,
        )?) {
            if let Some(p) = ui(p) {
                files.insert(p);
            }
        }
        let staged = strings(git(&g, &["diff", "--cached", "--name-only", "-z"], None)?);
        let mut changed: HashSet<String> = staged.iter().cloned().collect();
        changed.extend(strings(git(&g, &["diff", "--name-only", "-z"], None)?));
        changed.extend(strings(git(
            &g,
            &["ls-files", "--others", "--exclude-standard", "-z"],
            None,
        )?));
        r.staged = staged.into_iter().filter_map(&ui).collect();
        r.changed = changed.into_iter().filter_map(ui).collect();
        r.changed.sort();
    } else {
        walk(Path::new(&root), Path::new(&root), &mut files);
    }
    r.files = files.into_iter().collect();
    Ok(r)
}
pub fn path(r: &Repo, p: &str) -> Result<PathBuf, String> {
    if p.is_empty()
        || Path::new(p)
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err("Invalid file path".into());
    }
    let full = Path::new(&r.root).join(p);
    let check = if full.exists() {
        full.canonicalize()
    } else {
        full.parent().unwrap().canonicalize()
    }
    .map_err(|e| e.to_string())?;
    if !check.starts_with(&r.root) {
        return Err("File resolves outside the opened folder".into());
    }
    Ok(full)
}
pub fn disk(r: &Repo, p: &str) -> Result<Option<String>, String> {
    let p = path(r, p)?;
    match fs::read(&p) {
        Ok(v) => {
            if v.contains(&0) {
                return Err("Binary files cannot be edited".into());
            }
            String::from_utf8(v)
                .map(Some)
                .map_err(|_| "File is not UTF-8".into())
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}
fn git_path(r: &Repo, p: &str) -> String {
    if r.prefix.is_empty() {
        p.into()
    } else {
        format!("{}/{p}", r.prefix)
    }
}
pub fn base(r: &Repo, p: &str) -> Result<String, String> {
    let Some(g) = &r.git_root else {
        return Ok(String::new());
    };
    let spec = format!("HEAD:{}", git_path(r, p));
    match git(g, &["show", &spec], None) {
        Ok(v) => String::from_utf8(v).map_err(|_| "Committed file is not UTF-8".into()),
        Err(_) => Ok(String::new()),
    }
}
pub fn save(r: &Repo, p: &str, text: &str, expected: &Option<String>) -> Result<(), String> {
    if &disk(r, p)? != expected {
        return Err("EXTERNAL_CHANGE".into());
    }
    let raw_target = path(r, p)?;
    let target = if raw_target.exists() {
        raw_target.canonicalize().map_err(|e| e.to_string())?
    } else {
        raw_target
    };
    // Write through a same-directory temporary file, retaining existing permissions.
    let temp = target.with_file_name(format!(
        ".diffedit-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        file.write_all(text.as_bytes()).map_err(|e| e.to_string())?;
        if let Ok(m) = fs::metadata(&target) {
            fs::set_permissions(&temp, m.permissions()).map_err(|e| e.to_string())?;
        }
        file.sync_all().map_err(|e| e.to_string())?;
        if &disk(r, p)? != expected {
            return Err("EXTERNAL_CHANGE".into());
        }
        fs::rename(&temp, &target).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temp);
    }
    result
}
pub fn stage(r: &Repo, p: &str, text: &str) -> Result<(), String> {
    let g = r.git_root.as_ref().ok_or("Not a Git repository")?;
    path(r, p)?;
    let gp = git_path(r, p);
    let entry = git(g, &["ls-files", "--stage", "--", &gp], None)?;
    let entry = String::from_utf8_lossy(&entry);
    #[cfg(unix)]
    let fallback = {
        use std::os::unix::fs::PermissionsExt;
        if fs::metadata(path(r, p)?)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
        {
            "100755"
        } else {
            "100644"
        }
    };
    #[cfg(not(unix))]
    let fallback = "100644";
    let mode = entry.split_whitespace().next().unwrap_or(fallback);
    if text.is_empty() && git(g, &["cat-file", "-e", &format!("HEAD:{gp}")], None).is_err() {
        git(g, &["update-index", "--force-remove", "--", &gp], None)?;
        return Ok(());
    }
    let oid = git(
        g,
        &["hash-object", "-w", "--stdin", &format!("--path={gp}")],
        Some(text.as_bytes()),
    )?;
    let oid = String::from_utf8_lossy(&oid);
    git(
        g,
        &[
            "update-index",
            "--add",
            "--cacheinfo",
            mode,
            oid.trim(),
            &gp,
        ],
        None,
    )?;
    Ok(())
}
pub fn validate_commit(r: &Repo, message: &str) -> Result<(), String> {
    let g = r.git_root.as_ref().ok_or("Not a Git repository")?;
    if message.trim().is_empty() {
        return Err("Enter a commit summary".into());
    }
    let paths = strings(git(g, &["diff", "--cached", "--name-only", "-z"], None)?);
    let invisible: Vec<_> = paths
        .iter()
        .filter(|p| !r.prefix.is_empty() && !p.starts_with(&(r.prefix.clone() + "/")))
        .collect();
    if !invisible.is_empty() {
        return Err(format!("Staged files outside this folder: {invisible:?}. Open the repository root before committing."));
    }
    Ok(())
}
pub fn commit(r: &Repo, message: &str) -> Result<String, String> {
    validate_commit(r, message)?;
    let g = r.git_root.as_ref().ok_or("Not a Git repository")?;
    git(g, &["commit", "-F", "-"], Some(message.as_bytes()))
        .map(|v| String::from_utf8_lossy(&v).into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn git_staging_and_external_conflict() {
        let root = std::env::temp_dir().join(format!("diffedit-test-{}", std::process::id()));
        fs::create_dir_all(root.join("sub")).unwrap();
        let root = root.to_str().unwrap();
        git(root, &["init", "-q"], None).unwrap();
        git(root, &["config", "user.name", "DiffEdit Test"], None).unwrap();
        git(
            root,
            &["config", "user.email", "test@example.invalid"],
            None,
        )
        .unwrap();
        fs::write(Path::new(root).join("sub/a.txt"), "old\n").unwrap();
        fs::write(Path::new(root).join("outside.txt"), "old\n").unwrap();
        git(root, &["add", "."], None).unwrap();
        git(root, &["commit", "-qm", "initial"], None).unwrap();
        let r = discover(&format!("{root}/sub")).unwrap();
        stage(&r, "a.txt", "unsaved\n").unwrap();
        assert_eq!(disk(&r, "a.txt").unwrap().unwrap(), "old\n");
        assert_eq!(
            git(root, &["show", ":sub/a.txt"], None).unwrap(),
            b"unsaved\n"
        );
        fs::write(Path::new(root).join("sub/a.txt"), "external\n").unwrap();
        assert_eq!(
            save(&r, "a.txt", "mine\n", &Some("old\n".into())).unwrap_err(),
            "EXTERNAL_CHANGE"
        );
        assert_eq!(disk(&r, "a.txt").unwrap().unwrap(), "external\n");
        fs::write(Path::new(root).join("outside.txt"), "changed\n").unwrap();
        git(root, &["add", "outside.txt"], None).unwrap();
        assert!(commit(&r, "blocked").unwrap_err().contains("outside"));
        assert!(path(&r, "../outside.txt").is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
