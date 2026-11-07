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
    pub head: Option<String>,
    #[serde(skip)]
    pub reference: Option<String>,
    pub index: String,
    pub branch: String,
    pub files: Vec<String>,
    #[serde(skip)]
    pub search: Vec<String>,
    pub changed: Vec<String>,
    pub staged: Vec<String>,
}
pub fn git(root: &str, args: &[&str], input: Option<&[u8]>) -> Result<Vec<u8>, String> {
    git_index(root, args, input, None)
}
fn git_index(
    root: &str,
    args: &[&str],
    input: Option<&[u8]>,
    index: Option<&Path>,
) -> Result<Vec<u8>, String> {
    git_with_timeout(
        root,
        args,
        input,
        index,
        std::time::Duration::from_secs(120),
    )
}
fn git_with_timeout(
    root: &str,
    args: &[&str],
    input: Option<&[u8]>,
    index: Option<&Path>,
    timeout: std::time::Duration,
) -> Result<Vec<u8>, String> {
    let mut command = Command::new("git");
    for key in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ] {
        command.env_remove(key);
    }
    if let Some(index) = index {
        command.env("GIT_INDEX_FILE", index);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_LITERAL_PATHSPECS", "1")
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
    let pid = child.id();
    let (send, receive) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let _ = send.send(child.wait_with_output());
    });
    let result = receive.recv_timeout(timeout);
    let timed_out = matches!(result, Err(std::sync::mpsc::RecvTimeoutError::Timeout));
    if timed_out {
        #[cfg(unix)]
        unsafe {
            unsafe extern "C" {
                fn kill(pid: i32, signal: i32) -> i32;
            }
            kill(-(pid as i32), 9);
        }
        let _ = receive.recv_timeout(std::time::Duration::from_secs(2));
    }
    let out = result
        .map_err(|_| "Git operation timed out; check repository state before retrying")?
        .map_err(|e| e.to_string())?;
    let written = writer.map(|w| {
        w.join()
            .map_err(|_| "Git input failed".to_string())
            .and_then(|r| r.map_err(|e| e.to_string()))
    });
    if out.status.success() {
        if let Some(result) = written {
            result?;
        }
        Ok(out.stdout)
    } else {
        let stderr = String::from_utf8_lossy(&out.stderr);
        let stdout = String::from_utf8_lossy(&out.stdout);
        let message = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        Err(if message.is_empty() {
            format!("Git exited with {}", out.status)
        } else {
            message.into()
        })
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
        .map(|v| {
            String::from_utf8_lossy(&v)
                .strip_suffix("\n")
                .unwrap_or(&String::from_utf8_lossy(&v))
                .to_string()
        });
    let mut r = Repo {
        root: root.clone(),
        git_root: git_root.clone(),
        prefix: String::new(),
        head: None,
        reference: None,
        index: String::new(),
        branch: String::new(),
        files: vec![],
        search: vec![],
        changed: vec![],
        staged: vec![],
    };
    let mut files = BTreeSet::new();
    if let Some(g) = git_root {
        r.head = head(&g)?;
        r.index = index_signature(&g)?;
        r.prefix = Path::new(&root)
            .strip_prefix(&g)
            .map_err(|e| e.to_string())?
            .to_string_lossy()
            .into();
        r.reference = reference(&g);
        r.branch = r
            .reference
            .as_deref()
            .map(|r| r.strip_prefix("refs/heads/").unwrap_or(r).to_string())
            .unwrap_or_else(|| "HEAD".into());
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
        let staged = strings(git(
            &g,
            &["diff", "--no-renames", "--cached", "--name-only", "-z"],
            None,
        )?);
        let mut changed: HashSet<String> = staged.iter().cloned().collect();
        changed.extend(strings(git(
            &g,
            &["diff", "--no-renames", "--name-only", "-z"],
            None,
        )?));
        changed.extend(strings(git(
            &g,
            &["ls-files", "--others", "--exclude-standard", "-z"],
            None,
        )?));
        r.staged = staged.into_iter().filter_map(&ui).collect();
        r.changed = changed.into_iter().filter_map(ui).collect();
        r.changed.sort();
        files.extend(r.changed.iter().cloned());
    } else {
        walk(Path::new(&root), Path::new(&root), &mut files);
    }
    r.files = files.into_iter().collect();
    r.search = r.files.iter().map(|p| p.to_lowercase()).collect();
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
    // Validate every existing ancestor, including dangling symlinks. Missing
    // directories are valid for deleted files and can be recreated on save.
    let mut ancestor = full.as_path();
    while fs::symlink_metadata(ancestor).is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound) {
        ancestor = ancestor.parent().ok_or("Invalid file path")?;
    }
    let check = ancestor.canonicalize().map_err(|e| e.to_string())?;
    if !check.starts_with(&r.root) {
        return Err("File resolves outside the opened folder".into());
    }
    Ok(full)
}
pub fn disk(r: &Repo, p: &str) -> Result<Option<String>, String> {
    let p = path(r, p)?;
    if fs::symlink_metadata(&p).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err("Symbolic links cannot be edited as regular files".into());
    }
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
pub fn base_entry(r: &Repo, p: &str) -> Result<Option<String>, String> {
    match (&r.git_root, &r.head) {
        (Some(g), Some(head)) => blob(g, &format!("{head}:{}", git_path(r, p))),
        _ => Ok(None),
    }
}
#[cfg(test)]
pub fn base(r: &Repo, p: &str) -> Result<String, String> {
    base_entry(r, p).map(Option::unwrap_or_default)
}
fn blob(g: &str, spec: &str) -> Result<Option<String>, String> {
    // Verify the tree/index separately so missing paths do not hide Git errors.
    let out = git(
        g,
        &["cat-file", "--batch", "-z"],
        Some(format!("{spec}\0").as_bytes()),
    )?;
    let split = out
        .iter()
        .position(|b| *b == b'\n')
        .ok_or("Invalid Git object response")?;
    let header = std::str::from_utf8(&out[..split]).map_err(|e| e.to_string())?;
    if header.ends_with(" missing") {
        return Ok(None);
    }
    let fields: Vec<_> = header.split_whitespace().collect();
    if fields.len() != 3 || fields[1] != "blob" {
        return Err("Only regular text files can be edited".into());
    }
    let size: usize = fields[2].parse().map_err(|_| "Invalid Git object size")?;
    let bytes = out
        .get(split + 1..split + 1 + size)
        .ok_or("Truncated Git object")?;
    if bytes.contains(&0) {
        return Err("Binary files cannot be edited".into());
    }
    String::from_utf8(bytes.to_vec())
        .map(Some)
        .map_err(|_| "File is not UTF-8".into())
}
pub fn validate_file_mode(r: &Repo, p: &str) -> Result<(), String> {
    let Some(g) = &r.git_root else {
        return Ok(());
    };
    let gp = git_path(r, p);
    let entry = git(g, &["ls-files", "--stage", "-z", "--", &gp], None)?;
    let entry = String::from_utf8_lossy(&entry);
    let mut mode = None;
    for row in entry.split('\0').filter(|r| !r.is_empty()) {
        let fields: Vec<_> = row.split_whitespace().collect();
        if fields.len() < 3 || fields[2] != "0" || !matches!(fields[0], "100644" | "100755") {
            return Err(
                "Resolve merge conflicts and non-regular files outside DiffEdit before staging"
                    .into(),
            );
        }
        mode = Some(fields[0]);
    }
    let base = if let Some(head) = &r.head {
        git(g, &["ls-tree", "-z", head, "--", &gp], None)?
    } else {
        Vec::new()
    };
    let base = String::from_utf8_lossy(&base);
    let base_mode = base.split_whitespace().next();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let disk_mode = fs::metadata(path(r, p)?).ok().map(|m| {
            if m.permissions().mode() & 0o111 != 0 {
                "100755"
            } else {
                "100644"
            }
        });
        if base_mode.is_some()
            && (mode.is_some_and(|m| Some(m) != base_mode)
                || disk_mode.is_some_and(|m| Some(m) != base_mode))
        {
            return Err("File permissions changed; handle mode changes with Git before reviewing text changes".into());
        }
    }
    Ok(())
}
pub fn index_text(r: &Repo, p: &str) -> Result<Option<String>, String> {
    let g = r.git_root.as_ref().ok_or("Not a Git repository")?;
    blob(g, &format!(":{}", git_path(r, p)))
}
fn head(g: &str) -> Result<Option<String>, String> {
    let resolved = git(g, &["rev-parse", "--verify", "HEAD"], None);
    match resolved {
        Ok(bytes) => {
            git(
                g,
                &["cat-file", "-e", String::from_utf8_lossy(&bytes).trim()],
                None,
            )?;
            Ok(Some(String::from_utf8_lossy(&bytes).trim().into()))
        }
        Err(error) => {
            // A symbolic HEAD with no corresponding ref is an unborn branch.
            let symbolic = git(g, &["symbolic-ref", "HEAD"], None)?;
            let name = String::from_utf8_lossy(&symbolic);
            let listed = git(
                g,
                &["for-each-ref", "--format=%(refname)", name.trim()],
                None,
            )?;
            if listed.is_empty() {
                Ok(None)
            } else {
                Err(error)
            }
        }
    }
}
pub fn index_signature(g: &str) -> Result<String, String> {
    use std::hash::{Hash, Hasher};
    let entries = git(g, &["ls-files", "--stage", "-z"], None)?;
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    entries.hash(&mut hash);
    Ok(format!("{:x}", hash.finish()))
}
fn reference(g: &str) -> Option<String> {
    git(g, &["symbolic-ref", "--quiet", "HEAD"], None)
        .ok()
        .map(|b| String::from_utf8_lossy(&b).trim().into())
}
pub fn verify(r: &Repo, expected_index: &str) -> Result<(), String> {
    let g = r.git_root.as_ref().ok_or("Not a Git repository")?;
    if head(g)? != r.head || reference(g) != r.reference {
        return Err("HEAD changed; refresh and review the changes again".into());
    }
    if index_signature(g)? != expected_index {
        return Err("Git staging changed; refresh and review the selection again".into());
    }
    Ok(())
}

pub fn save(r: &Repo, p: &str, text: &str, expected: &Option<String>) -> Result<(), String> {
    if &disk(r, p)? != expected {
        return Err("EXTERNAL_CHANGE".into());
    }
    let raw_target = path(r, p)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if fs::metadata(&raw_target).is_ok_and(|m| m.nlink() > 1) {
            return Err("Saving would replace a hard-linked file; edit it outside DiffEdit".into());
        }
    }
    fs::create_dir_all(raw_target.parent().unwrap()).map_err(|e| e.to_string())?;
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
            #[cfg(target_os = "macos")]
            {
                use std::os::fd::AsRawFd;
                unsafe extern "C" {
                    fn fcopyfile(
                        from: i32,
                        to: i32,
                        state: *mut std::ffi::c_void,
                        flags: u32,
                    ) -> i32;
                }
                let original = fs::File::open(&target).map_err(|e| e.to_string())?;
                // COPYFILE_ACL | COPYFILE_XATTR, from the macOS copyfile API.
                if unsafe {
                    fcopyfile(
                        original.as_raw_fd(),
                        file.as_raw_fd(),
                        std::ptr::null_mut(),
                        5,
                    )
                } != 0
                {
                    return Err(std::io::Error::last_os_error().to_string());
                }
            }
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
fn stage_entry(r: &Repo, p: &str, text: Option<&str>, index: Option<&Path>) -> Result<(), String> {
    let g = r.git_root.as_ref().ok_or("Not a Git repository")?;
    validate_file_mode(r, p)?;
    let full = path(r, p)?;
    if fs::symlink_metadata(&full).is_ok_and(|m| !m.is_file()) {
        return Err("Only regular files can be staged".into());
    }
    let gp = git_path(r, p);
    let entry = git_index(g, &["ls-files", "--stage", "-z", "--", &gp], None, index)?;
    let entry = String::from_utf8_lossy(&entry);
    for e in entry.split('\0').filter(|s| !s.is_empty()) {
        let fields: Vec<_> = e.split_whitespace().collect();
        if fields.len() < 3 || fields[2] != "0" || !matches!(fields[0], "100644" | "100755") {
            return Err(
                "Resolve merge conflicts and non-regular files outside DiffEdit before staging"
                    .into(),
            );
        }
    }
    let Some(text) = text else {
        git_index(
            g,
            &["update-index", "--force-remove", "--", &gp],
            None,
            index,
        )?;
        return Ok(());
    };
    #[cfg(unix)]
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(&full)
            .ok()
            .map(|m| {
                if m.permissions().mode() & 0o111 != 0 {
                    "100755"
                } else {
                    "100644"
                }
            })
            .unwrap_or_else(|| entry.split_whitespace().next().unwrap_or("100644"))
    };
    #[cfg(not(unix))]
    let mode = entry.split_whitespace().next().unwrap_or("100644");
    let oid = git(
        g,
        &["hash-object", "-w", "--stdin", &format!("--path={gp}")],
        Some(text.as_bytes()),
    )?;
    git_index(
        g,
        &[
            "update-index",
            "--add",
            "--cacheinfo",
            mode,
            String::from_utf8_lossy(&oid).trim(),
            &gp,
        ],
        None,
        index,
    )?;
    Ok(())
}

// Lock the real index and prepare changes in a private copy. Validation and hook
// failures leave the real index untouched; successful commits install its exact
// resulting index. Other windows and external Git writers obey index.lock too.
pub fn apply_selection(
    r: &Repo,
    expected_index: &str,
    entries: &[(String, Option<String>)],
    message: Option<&str>,
) -> Result<String, String> {
    let g = r.git_root.as_ref().ok_or("Not a Git repository")?;
    let index_path = git(
        g,
        &["rev-parse", "--path-format=absolute", "--git-path", "index"],
        None,
    )?;
    let index_path = PathBuf::from(
        String::from_utf8(index_path)
            .map_err(|e| e.to_string())?
            .trim_end_matches('\n'),
    );
    let lock_path = index_path.with_extension("lock");
    let _lock_file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&lock_path)
        .map_err(|e| format!("Could not lock Git index: {e}"))?;
    struct Cleanup(Vec<PathBuf>);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            for p in &self.0 {
                let _ = fs::remove_file(p);
            }
        }
    }
    let temp = index_path.with_file_name(format!(
        "diffedit-index-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _cleanup = Cleanup(vec![
        lock_path.clone(),
        temp.clone(),
        temp.with_extension("lock"),
    ]);
    verify(r, expected_index)?;
    if index_path.exists() {
        fs::copy(&index_path, &temp).map_err(|e| e.to_string())?;
    } else {
        git_index(g, &["read-tree", "--empty"], None, Some(&temp))?;
    }
    for (path, text) in entries {
        stage_entry(r, path, text.as_deref(), Some(&temp))?;
    }
    // Never allow an incomplete selection request to commit an unseen index path.
    let mut output = String::new();
    if let Some(message) = message {
        if message.trim().is_empty() {
            return Err("Enter a commit summary".into());
        }
        let paths = strings(git_index(
            g,
            &["diff", "--no-renames", "--cached", "--name-only", "-z"],
            None,
            Some(&temp),
        )?);
        let allowed: HashSet<_> = entries.iter().map(|(p, _)| git_path(r, p)).collect();
        if paths.iter().any(|p| !allowed.contains(p)) {
            return Err(
                "Staged files outside the reviewed selection; refresh or open the repository root"
                    .into(),
            );
        }
        verify(r, expected_index)?;
        output = String::from_utf8_lossy(&git_index(
            g,
            &["commit", "-F", "-"],
            Some(message.as_bytes()),
            Some(&temp),
        )?)
        .into();
    }
    fs::File::open(&temp)
        .and_then(|f| f.sync_all())
        .map_err(|e| e.to_string())?;
    fs::rename(&temp, &lock_path).map_err(|e| e.to_string())?;
    fs::rename(&lock_path, &index_path)
        .map_err(|e| format!("Git operation finished but index installation failed: {e}"))?;
    Ok(output)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn git_timeout_terminates_a_stuck_subprocess() {
        let started = std::time::Instant::now();
        let error = git_with_timeout(
            "/tmp",
            &["-c", "alias.wait=!sleep 30", "wait"],
            None,
            None,
            std::time::Duration::from_millis(100),
        )
        .unwrap_err();
        assert!(error.contains("timed out"));
        assert!(started.elapsed() < std::time::Duration::from_secs(3));
    }
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
        apply_selection(
            &r,
            &r.index,
            &[("a.txt".into(), Some("unsaved\n".into()))],
            None,
        )
        .unwrap();
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
        let r = discover(&format!("{root}/sub")).unwrap();
        assert!(apply_selection(&r, &r.index, &[], Some("blocked"))
            .unwrap_err()
            .contains("outside"));
        assert!(path(&r, "../outside.txt").is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
