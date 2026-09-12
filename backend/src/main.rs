mod app_menu;
mod diff;
mod repository;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
};
use tauri::{Emitter, Manager};
use tauri_plugin_dialog::DialogExt;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Document {
    path: String,
    text: String,
    base: String,
    disk: Option<String>,
    version: u64,
}
#[derive(Default)]
struct Workspace {
    repo: Option<repository::Repo>,
    documents: HashMap<String, Document>,
}
#[derive(Default, Clone)]
struct Service(Arc<Mutex<HashMap<String, Arc<Mutex<Workspace>>>>>);
impl Service {
    fn workspace(&self, label: &str) -> Arc<Mutex<Workspace>> {
        self.0
            .lock()
            .unwrap()
            .entry(label.into())
            .or_default()
            .clone()
    }
}
#[derive(Deserialize)]
struct Edit {
    from: usize,
    to: usize,
    insert: String,
}
#[derive(Serialize)]
struct Update {
    version: u64,
    diff: diff::DiffResult,
}
async fn work<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|e| e.to_string())?
}
#[derive(Default)]
struct FolderWindows(Mutex<HashMap<String, String>>);
struct Startup(std::time::Instant);
#[tauri::command]
fn show_ready(
    window: tauri::Window,
    state: tauri::State<'_, Startup>,
    shell_ms: f64,
) -> Result<(), String> {
    eprintln!(
        "startup window={} native_ms={:.1} shell_ms={shell_ms:.1}",
        window.label(),
        state.0.elapsed().as_secs_f64() * 1000.0
    );
    window.show().map_err(|e| e.to_string())?;
    window.set_focus().map_err(|e| e.to_string())
}
#[tauri::command]
async fn route_folder(
    app: tauri::AppHandle,
    window: tauri::Window,
    root: String,
    reuse: bool,
) -> Result<Option<String>, String> {
    route_folder_to_window(app, Some(window.label().to_owned()), root, reuse).await
}
async fn route_folder_to_window(
    app: tauri::AppHandle,
    source: Option<String>,
    root: String,
    reuse: bool,
) -> Result<Option<String>, String> {
    let root = work(move || {
        std::fs::canonicalize(root)
            .map(|p| p.to_string_lossy().into_owned())
            .map_err(|e| e.to_string())
    })
    .await?;
    let registry = app.state::<FolderWindows>();
    let mut folders = registry.0.lock().unwrap();
    if let Some(label) = folders.get(&root).cloned() {
        drop(folders);
        // Reopening an existing window still counts as the most recent folder.
        app.state::<app_menu::Controls>()
            .update_recent(&app, Some(root.clone()))?;
        if source.as_deref() == Some(label.as_str()) {
            return Ok(Some(root));
        }
        if let Some(existing) = app.get_webview_window(&label) {
            existing.unminimize().map_err(|e| e.to_string())?;
            existing.set_focus().map_err(|e| e.to_string())?;
        }
        return Ok(None);
    }
    if let Some(source) = source.filter(|_| reuse) {
        folders.retain(|_, label| label != &source);
        folders.insert(root.clone(), source);
        return Ok(Some(root));
    }
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let label = format!("folder-{}", NEXT.fetch_add(1, Ordering::Relaxed));
    folders.insert(root.clone(), label.clone());
    drop(folders);
    let mut url = tauri::Url::parse("http://localhost/index.html").unwrap();
    url.query_pairs_mut().append_pair("folder", &root);
    let path = format!("index.html?{}", url.query().unwrap());
    if let Err(e) =
        tauri::WebviewWindowBuilder::new(&app, &label, tauri::WebviewUrl::App(path.into()))
            .title("DiffEdit")
            .visible(false)
            .background_color(tauri::window::Color(36, 36, 40, 255))
            .inner_size(1200.0, 820.0)
            .min_inner_size(650.0, 400.0)
            .build()
    {
        registry.0.lock().unwrap().remove(&root);
        return Err(e.to_string());
    }
    Ok(None)
}
// A picker never needs a webview. Reserve a folder only after selection.
fn pick_folder_window(app: &tauri::AppHandle) {
    static PICKING: AtomicBool = AtomicBool::new(false);
    if PICKING.swap(true, Ordering::SeqCst) {
        return;
    }
    let handle = app.clone();
    app.dialog().file().pick_folder(move |folder| {
        PICKING.store(false, Ordering::SeqCst);
        let Some(folder) = folder else {
            return;
        };
        tauri::async_runtime::spawn(async move {
            let result = match folder.into_path() {
                Ok(path) => route_folder_to_window(
                    handle.clone(),
                    None,
                    path.to_string_lossy().into_owned(),
                    false,
                )
                .await
                .map(|_| ()),
                Err(error) => Err(error.to_string()),
            };
            if let Err(error) = result {
                handle
                    .dialog()
                    .message(error)
                    .title("Could not open folder")
                    .show(|_| {});
            }
        });
    });
}
#[tauri::command]
async fn quick_matches(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    query: String,
) -> Result<Vec<String>, String> {
    let w = state.workspace(window.label());
    work(move || {
        let files = w
            .lock()
            .unwrap()
            .repo
            .as_ref()
            .map(|r| r.files.clone())
            .unwrap_or_default();
        let parts: Vec<_> = query.split_whitespace().map(str::to_lowercase).collect();
        Ok(files
            .into_iter()
            .filter(|p| {
                let p = p.to_lowercase();
                parts.iter().all(|q| p.contains(q))
            })
            .collect())
    })
    .await
}
#[derive(Deserialize)]
struct CommitSelection {
    path: String,
    version: u64,
    selected: HashSet<String>,
}
#[tauri::command]
fn resize_grid(window: tauri::Window, line: f64, delta: f64) -> Result<(), String> {
    if !line.is_finite()
        || !(1.0..=100.0).contains(&line)
        || !delta.is_finite()
        || delta.abs() > line
    {
        return Err("Invalid resize grid".into());
    }
    #[cfg(target_os = "macos")]
    {
        let target = window.clone();
        window
            .run_on_main_thread(move || {
                if let Ok(ptr) = target.ns_window() {
                    let native = unsafe { &*(ptr as *const objc2_app_kit::NSWindow) };
                    native.setContentResizeIncrements(objc2_foundation::NSSize::new(1.0, line));
                    // Keep the top edge fixed, and leave fullscreen/zoomed layouts to macOS.
                    if delta.abs() > 0.5
                        && !native.isZoomed()
                        && !native
                            .styleMask()
                            .contains(objc2_app_kit::NSWindowStyleMask::FullScreen)
                    {
                        let mut frame = native.frame();
                        if frame.size.height + delta >= native.minSize().height {
                            frame.size.height += delta;
                            frame.origin.y -= delta;
                            native.setFrame_display(frame, true);
                        }
                    }
                }
            })
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
#[tauri::command]
fn document_path(window: tauri::Window, path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let target = window.clone();
        window
            .run_on_main_thread(move || {
                if let Ok(ptr) = target.ns_window() {
                    // Tauri owns the NSWindow; access is confined to its main thread.
                    let native = unsafe { &*(ptr as *const objc2_app_kit::NSWindow) };
                    native.setRepresentedFilename(&objc2_foundation::NSString::from_str(&path));
                }
            })
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
#[tauri::command]
async fn open_folder(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    root: String,
) -> Result<repository::Repo, String> {
    let w = state.workspace(window.label());
    work(move || {
        let r = repository::discover(&root)?;
        let mut w = w.lock().unwrap();
        w.documents.clear();
        w.repo = Some(r.clone());
        Ok(r)
    })
    .await
}
#[tauri::command]
async fn refresh(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
) -> Result<repository::Repo, String> {
    let w = state.workspace(window.label());
    work(move || {
        let mut w = w.lock().unwrap();
        let r = repository::discover(&w.repo.as_ref().ok_or("Open a folder first")?.root)?;
        w.repo = Some(r.clone());
        Ok(r)
    })
    .await
}
#[tauri::command]
async fn open_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
) -> Result<Document, String> {
    let w = state.workspace(window.label());
    work(move || {
        let mut w = w.lock().unwrap();
        if let Some(d) = w.documents.get(&path) {
            return Ok(d.clone());
        }
        let r = w.repo.as_ref().ok_or("Open a folder first")?;
        let disk = repository::disk(r, &path)?;
        let d = Document {
            path: path.clone(),
            text: disk.clone().unwrap_or_default(),
            base: repository::base(r, &path)?,
            disk,
            version: 0,
        };
        w.documents.insert(path, d.clone());
        Ok(d)
    })
    .await
}
#[tauri::command]
async fn edit_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
    version: u64,
    edits: Vec<Edit>,
) -> Result<Update, String> {
    let w = state.workspace(window.label());
    work(move || {
        let (text, base) = {
            let mut w = w.lock().unwrap();
            let d = w.documents.get_mut(&path).ok_or("Document not open")?;
            if version != d.version + 1 {
                return Err("Document version mismatch".into());
            }
            let mut next = d.text.clone();
            for e in edits.iter().rev() {
                let from = diff::byte_at(&next, e.from)?;
                let to = diff::byte_at(&next, e.to)?;
                if to < from {
                    return Err("Invalid edit".into());
                }
                next.replace_range(from..to, &e.insert);
            }
            d.text = next;
            d.version = version;
            (d.text.clone(), d.base.clone())
        };
        Ok(Update {
            version,
            diff: diff::compute(&base, &text),
        })
    })
    .await
}
#[tauri::command]
async fn document_diff(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
) -> Result<Update, String> {
    let w = state.workspace(window.label());
    work(move || {
        let d = w
            .lock()
            .unwrap()
            .documents
            .get(&path)
            .ok_or("Document not open")?
            .clone();
        Ok(Update {
            version: d.version,
            diff: diff::compute(&d.base, &d.text),
        })
    })
    .await
}
#[tauri::command]
async fn inspect_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
) -> Result<Document, String> {
    let w = state.workspace(window.label());
    work(move || {
        let mut w = w.lock().unwrap();
        let r = w.repo.as_ref().ok_or("No repository")?.clone();
        let base = repository::base(&r, &path)?;
        let disk = repository::disk(&r, &path)?;
        let d = w.documents.get_mut(&path).ok_or("Document not open")?;
        d.base = base;
        let mut result = d.clone();
        result.disk = disk;
        Ok(result)
    })
    .await
}
#[tauri::command]
async fn resolve_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
    reload: bool,
) -> Result<Document, String> {
    let w = state.workspace(window.label());
    work(move || {
        let mut w = w.lock().unwrap();
        let r = w.repo.as_ref().ok_or("No repository")?.clone();
        let disk = repository::disk(&r, &path)?;
        let d = w.documents.get_mut(&path).ok_or("Document not open")?;
        d.disk = disk;
        if reload {
            d.text = d.disk.clone().unwrap_or_default();
            d.version += 1;
        }
        Ok(d.clone())
    })
    .await
}
#[tauri::command]
async fn save_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
) -> Result<Document, String> {
    let w = state.workspace(window.label());
    work(move || {
        let mut w = w.lock().unwrap();
        let r = w.repo.as_ref().ok_or("No repository")?.clone();
        let d = w.documents.get_mut(&path).ok_or("Document not open")?;
        repository::save(&r, &path, &d.text, &d.disk)?;
        d.disk = Some(d.text.clone());
        Ok(d.clone())
    })
    .await
}
#[tauri::command]
async fn stage_rows(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
) -> Result<Vec<diff::StageRow>, String> {
    let w = state.workspace(window.label());
    work(move || {
        let d = w
            .lock()
            .unwrap()
            .documents
            .get(&path)
            .ok_or("Document not open")?
            .clone();
        Ok(diff::stage_rows(&d.base, &d.text))
    })
    .await
}
#[tauri::command]
async fn stage_selected(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
    selected: HashSet<String>,
    version: u64,
) -> Result<(), String> {
    let w = state.workspace(window.label());
    work(move || {
        let w = w.lock().unwrap();
        let r = w.repo.as_ref().ok_or("No repository")?;
        let d = w.documents.get(&path).ok_or("Document not open")?;
        if d.version != version {
            return Err("Document changed; review the staging selection again".into());
        }
        let rows = diff::stage_rows(&d.base, &d.text);
        let available: HashSet<_> = rows.iter().filter_map(|r| r.id.clone()).collect();
        if !selected.is_subset(&available) {
            return Err("Changes updated; review the selection again".into());
        }
        repository::stage(r, &path, &diff::staged_text(&rows, &selected))
    })
    .await
}
#[tauri::command]
async fn commit_changes(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    message: String,
    selection: Option<CommitSelection>,
) -> Result<String, String> {
    let w = state.workspace(window.label());
    work(move || {
        let w = w.lock().unwrap();
        commit_workspace(&w, &message, selection)
    })
    .await
}
fn commit_workspace(
    w: &Workspace,
    message: &str,
    selection: Option<CommitSelection>,
) -> Result<String, String> {
    let repo = w.repo.as_ref().ok_or("No repository")?;
    if message.trim().is_empty() {
        return Err("Enter a commit summary".into());
    }
    repository::validate_commit(repo, message)?;
    if let Some(selection) = selection {
        let d = w
            .documents
            .get(&selection.path)
            .ok_or("Document not open")?;
        if d.version != selection.version {
            return Err("Document changed before commit".into());
        }
        let rows = diff::stage_rows(&d.base, &d.text);
        if rows.iter().any(|r| r.id.is_some()) {
            repository::stage(
                repo,
                &selection.path,
                &diff::staged_text(&rows, &selection.selected),
            )?;
        }
    }
    repository::commit(repo, &message)
}
#[derive(Default)]
struct QuitState {
    pending: Mutex<Option<HashSet<String>>>,
    allowed: AtomicBool,
}
fn begin_quit(app: &tauri::AppHandle) {
    let q = app.state::<QuitState>();
    let windows = app.webview_windows();
    {
        let mut pending = q.pending.lock().unwrap();
        if pending.is_some() {
            return;
        }
        *pending = Some(windows.keys().cloned().collect());
    }
    if windows.is_empty() {
        q.allowed.store(true, Ordering::SeqCst);
        app.exit(0);
        return;
    }
    for w in windows.values() {
        let _ = w.emit("request-quit", ());
    }
}
#[tauri::command]
fn request_quit(app: tauri::AppHandle) {
    begin_quit(&app)
}
#[tauri::command]
fn quit_response(app: tauri::AppHandle, window: tauri::Window, approved: bool) {
    let q = app.state::<QuitState>();
    let mut pending = q.pending.lock().unwrap();
    if !approved {
        *pending = None;
        drop(pending);
        let _ = app.emit("quit-cancelled", ());
        return;
    }
    if let Some(labels) = pending.as_mut() {
        labels.remove(window.label());
        if labels.is_empty() {
            q.allowed.store(true, Ordering::SeqCst);
            *pending = None;
            drop(pending);
            app.exit(0);
        }
    }
}
fn main() {
    let args: Vec<_> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--benchmark") {
        if let Err(e) = diff::benchmark(&args[2..]) {
            eprintln!("{e}");
            std::process::exit(1)
        }
        return;
    }
    let startup = Startup(std::time::Instant::now());
    tauri::Builder::default()
        .enable_macos_default_menu(false)
        .menu(app_menu::build)
        .setup(|app| {
            if let Err(error) = app
                .state::<app_menu::Controls>()
                .initialize_recent(app.handle())
            {
                eprintln!("Could not load recent folders: {error}");
            }
            Ok(())
        })
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            if id == "clear-recent" || id.starts_with("recent:") {
                let app = app.clone();
                let id = id.to_owned();
                tauri::async_runtime::spawn(async move {
                    let result = if let Some(root) = id.strip_prefix("recent:") {
                        route_folder_to_window(app.clone(), None, root.to_owned(), false)
                            .await
                            .map(|_| ())
                    } else {
                        let handle = app.clone();
                        work(move || {
                            handle
                                .state::<app_menu::Controls>()
                                .update_recent(&handle, None)
                        })
                        .await
                    };
                    if let Err(error) = result {
                        app.dialog().message(error).show(|_| {});
                    }
                });
                return;
            }
            for window in app.webview_windows().values() {
                if window.is_focused().unwrap_or(false) {
                    let _ = app.emit_to(window.label(), "menu-action", event.id().as_ref());
                    return;
                }
            }
            match event.id().as_ref() {
                "quit" => begin_quit(app),
                "open" => pick_folder_window(app),
                _ => {}
            }
        })
        .plugin(tauri_plugin_dialog::init())
        .manage(startup)
        .manage(Service::default())
        .manage(FolderWindows::default())
        .manage(QuitState::default())
        .invoke_handler(tauri::generate_handler![
            app_menu::menu_state,
            app_menu::remember_folder,
            show_ready,
            document_path,
            resize_grid,
            route_folder,
            quick_matches,
            request_quit,
            quit_response,
            open_folder,
            refresh,
            open_document,
            edit_document,
            document_diff,
            inspect_document,
            resolve_document,
            save_document,
            stage_rows,
            stage_selected,
            commit_changes
        ])
        .build(tauri::generate_context!())
        .expect("Failed to run DiffEdit")
        .run(|app, event| {
            if let tauri::RunEvent::Ready = event {
                pick_folder_window(app);
            }
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen {
                has_visible_windows: false,
                ..
            } = event
            {
                pick_folder_window(app);
            }
            if let tauri::RunEvent::ExitRequested { ref api, code, .. } = event {
                if !app.state::<QuitState>().allowed.load(Ordering::SeqCst) {
                    api.prevent_exit();
                    if code.is_some() {
                        begin_quit(app);
                    }
                }
            }
            if let tauri::RunEvent::WindowEvent {
                label,
                event: tauri::WindowEvent::Destroyed,
                ..
            } = event
            {
                app.state::<Service>().0.lock().unwrap().remove(&label);
                app.state::<FolderWindows>()
                    .0
                    .lock()
                    .unwrap()
                    .retain(|_, value| value != &label);
                if app.webview_windows().keys().all(|key| key == &label) {
                    app.state::<app_menu::Controls>().idle();
                }
            }
        });
}

#[cfg(test)]
mod parity_tests {
    use super::*;
    #[test]
    fn selected_commit_preserves_unselected_work_and_rejects_stale_versions() {
        let root =
            std::env::temp_dir().join(format!("diffedit-commit-parity-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let git = |args: &[&str]| {
            let output = std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(args)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap()
        };
        git(&["init", "-q"]);
        git(&["config", "user.name", "DiffEdit Test"]);
        git(&["config", "user.email", "test@example.invalid"]);
        let base = "old first\nunchanged anchor\nold second\n";
        let text = "new first\nunchanged anchor\nnew second\n";
        std::fs::write(root.join("a.txt"), base).unwrap();
        git(&["add", "a.txt"]);
        git(&["commit", "-qm", "initial"]);
        std::fs::write(root.join("a.txt"), text).unwrap();
        let w = Workspace {
            repo: Some(repository::discover(root.to_str().unwrap()).unwrap()),
            documents: HashMap::from([(
                "a.txt".into(),
                Document {
                    path: "a.txt".into(),
                    text: text.into(),
                    base: base.into(),
                    disk: Some(text.into()),
                    version: 1,
                },
            )]),
        };
        let selected = diff::stage_rows(base, text)
            .into_iter()
            .filter(|r| r.old_line == Some(1) || r.new_line == Some(1))
            .filter_map(|r| r.id)
            .collect();
        commit_workspace(
            &w,
            "selected",
            Some(CommitSelection {
                path: "a.txt".into(),
                version: 1,
                selected,
            }),
        )
        .unwrap();
        assert_eq!(
            git(&["show", "HEAD:a.txt"]),
            "new first\nunchanged anchor\nold second\n"
        );
        assert_eq!(std::fs::read_to_string(root.join("a.txt")).unwrap(), text);
        let head = git(&["rev-parse", "HEAD"]);
        assert!(commit_workspace(
            &w,
            "stale",
            Some(CommitSelection {
                path: "a.txt".into(),
                version: 0,
                selected: HashSet::new()
            })
        )
        .is_err());
        assert_eq!(git(&["rev-parse", "HEAD"]), head);
        std::fs::remove_dir_all(root).unwrap();
    }
}
