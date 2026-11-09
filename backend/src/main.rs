mod app_menu;
mod diff;
mod document;
mod repository;
use document::{
    Document, Edit, Inspection, Resolved, ReviewSource, Saved, Selection, StageSnapshot, Update,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
};
use tauri::{Emitter, Manager};
use tauri_plugin_dialog::DialogExt;

#[derive(Default)]
struct Workspace {
    repo: Option<Arc<repository::Repo>>,
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
async fn work<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|e| e.to_string())?
}
#[derive(Default)]
struct FolderWindows(Mutex<HashMap<String, String>>);
const STARTUP_WINDOW: &str = "startup";
enum WarmWindow {
    Unavailable,
    Idle,
    Assigned(String),
}
struct Startup {
    started: std::time::Instant,
    warm: Mutex<WarmWindow>,
}

fn build_folder_window(
    app: &tauri::AppHandle,
    label: &str,
    path: String,
) -> tauri::Result<tauri::WebviewWindow> {
    let window = tauri::WebviewWindowBuilder::new(app, label, tauri::WebviewUrl::App(path.into()))
        .title("DiffEdit")
        .visible(false)
        .focused(false)
        .background_color(tauri::window::Color(36, 36, 40, 255))
        .inner_size(1200.0, 820.0)
        .min_inner_size(650.0, 400.0)
        .build()?;
    #[cfg(target_os = "macos")]
    window.with_webview(|platform| {
        use objc2_app_kit::NSColor;
        use objc2_web_kit::WKWebView;
        let color = NSColor::colorWithSRGBRed_green_blue_alpha(
            36.0 / 255.0,
            36.0 / 255.0,
            40.0 / 255.0,
            1.0,
        );
        // Tauri supplies the live WKWebView on its main thread. Set its
        // backing color as well as the native window's while WebKit paints.
        unsafe {
            let webview = &*platform.inner().cast::<WKWebView>();
            webview.setUnderPageBackgroundColor(Some(&color));
        }
    })?;
    Ok(window)
}

#[tauri::command]
fn take_startup_folder(
    window: tauri::Window,
    startup: tauri::State<'_, Startup>,
) -> Option<String> {
    if window.label() != STARTUP_WINDOW {
        return None;
    }
    let mut warm = startup.warm.lock().unwrap();
    if matches!(*warm, WarmWindow::Assigned(_)) {
        if let WarmWindow::Assigned(folder) = std::mem::replace(&mut *warm, WarmWindow::Unavailable)
        {
            return Some(folder);
        }
    }
    None
}

#[tauri::command]
fn show_ready(
    window: tauri::Window,
    state: tauri::State<'_, Startup>,
    shell_ms: f64,
) -> Result<(), String> {
    eprintln!(
        "startup window={} native_ms={:.1} shell_ms={shell_ms:.1}",
        window.label(),
        state.started.elapsed().as_secs_f64() * 1000.0
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
    if let Some(window) = app.get_webview_window(STARTUP_WINDOW) {
        let startup = app.state::<Startup>();
        let mut warm = startup.warm.lock().unwrap();
        if matches!(*warm, WarmWindow::Idle) {
            folders.insert(root.clone(), STARTUP_WINDOW.into());
            *warm = WarmWindow::Assigned(root);
            drop(warm);
            drop(folders);
            // The selection is stored until the frontend takes it. The event
            // only wakes an editor that has already installed its listener.
            window
                .emit("startup-folder", ())
                .map_err(|e| e.to_string())?;
            return Ok(None);
        }
    }
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let label = format!("folder-{}", NEXT.fetch_add(1, Ordering::Relaxed));
    folders.insert(root.clone(), label.clone());
    drop(folders);
    let mut url = tauri::Url::parse("http://localhost/index.html").unwrap();
    url.query_pairs_mut().append_pair("folder", &root);
    let path = format!("index.html?{}", url.query().unwrap());
    if let Err(e) = build_folder_window(&app, &label, path) {
        registry.0.lock().unwrap().remove(&root);
        return Err(e.to_string());
    }
    Ok(None)
}
fn pick_folder_window(app: &tauri::AppHandle) {
    static PICKING: AtomicBool = AtomicBool::new(false);
    if PICKING.swap(true, Ordering::SeqCst) {
        return;
    }
    let handle = app.clone();
    let done = move |folder: Option<String>| {
        PICKING.store(false, Ordering::SeqCst);
        let Some(folder) = folder else {
            return;
        };
        let handle = handle.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(error) = route_folder_to_window(handle.clone(), None, folder, false).await {
                handle
                    .dialog()
                    .message(error)
                    .title("Could not open folder")
                    .show(|_| {});
            }
        });
    };
    #[cfg(target_os = "macos")]
    {
        use objc2::MainThreadMarker;
        use objc2_app_kit::{NSModalResponseOK, NSOpenPanel};

        // A standalone panel stays visible while the hidden editor initializes.
        // The dialog plugin would attach a sheet to the hidden window.
        let mtm = MainThreadMarker::new().expect("folder picker runs on the main thread");
        let panel = NSOpenPanel::openPanel(mtm);
        panel.setCanChooseDirectories(true);
        panel.setCanChooseFiles(false);
        panel.setAllowsMultipleSelection(false);
        let selected = panel.clone();
        panel.beginWithCompletionHandler(&block2::RcBlock::new(move |response| {
            done(
                (response == NSModalResponseOK)
                    .then(|| selected.URL()?.path().map(|path| path.to_string()))
                    .flatten(),
            );
        }));
    }
    #[cfg(not(target_os = "macos"))]
    app.dialog().file().pick_folder(move |folder| {
        done(
            folder
                .and_then(|f| f.into_path().ok())
                .map(|p| p.to_string_lossy().into_owned()),
        );
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
        let repo = w.lock().unwrap().repo.clone();
        let parts: Vec<_> = query.split_whitespace().map(str::to_lowercase).collect();
        Ok(repo
            .as_ref()
            .map(|r| {
                r.files
                    .iter()
                    .zip(&r.search)
                    .filter(|(_, lower)| parts.iter().all(|q| lower.contains(q)))
                    .map(|(path, _)| path.clone())
                    .collect()
            })
            .unwrap_or_default())
    })
    .await
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
        w.repo = Some(Arc::new(r.clone()));
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
        let previous = w
            .lock()
            .unwrap()
            .repo
            .clone()
            .ok_or("Open a folder first")?;
        let r = repository::discover(&previous.root)?;
        let mut w = w.lock().unwrap();
        if !w.repo.as_ref().is_some_and(|p| Arc::ptr_eq(p, &previous)) {
            return Err("Workspace changed during refresh".into());
        }
        w.repo = Some(Arc::new(r.clone()));
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
        let repo = {
            let w = w.lock().unwrap();
            if let Some(d) = w.documents.get(&path) {
                return Ok(d.clone());
            }
            w.repo.clone().ok_or("Open a folder first")?
        };
        let d = Document::open(&repo, path.clone())?;
        let mut w = w.lock().unwrap();
        if !w
            .repo
            .as_ref()
            .is_some_and(|r| r.root == repo.root && r.head == repo.head)
        {
            return Err("Workspace changed while opening file".into());
        }
        Ok(w.documents.entry(path).or_insert(d).clone())
    })
    .await
}
// Only evict an unchanged native document. The frontend serializes release/open
// for each path and retains dirty documents, pending selections and undo history.
#[tauri::command]
fn release_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
    version: u64,
) -> Result<(), String> {
    let w = state.workspace(window.label());
    let mut w = w.lock().unwrap();
    if let Some(d) = w.documents.get(&path) {
        if d.version != version || d.text.as_str() != d.disk.as_deref().unwrap_or_default() {
            return Err("Document changed before cache release".into());
        }
    }
    w.documents.remove(&path);
    Ok(())
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
        let snapshot = {
            let mut w = w.lock().unwrap();
            let d = w.documents.get_mut(&path).ok_or("Document not open")?;
            d.edit(version, &edits)?;
            d.diff_input()
        };
        Ok(snapshot.update())
    })
    .await
}
#[tauri::command]
async fn sync_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
    text: String,
) -> Result<Update, String> {
    let w = state.workspace(window.label());
    work(move || {
        let snapshot = {
            let mut w = w.lock().unwrap();
            let d = w.documents.get_mut(&path).ok_or("Document not open")?;
            if d.text != text {
                d.text = text;
                d.version += 1;
            }
            d.diff_input()
        };
        Ok(snapshot.update())
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
            .diff_input();
        Ok(d.update())
    })
    .await
}
#[tauri::command]
async fn inspect_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
    head: Option<String>,
) -> Result<Inspection, String> {
    let w = state.workspace(window.label());
    work(move || {
        let repo = w.lock().unwrap().repo.clone().ok_or("No repository")?;
        let base = repository::base_entry(&repo, &path)?;
        let base_exists = base.is_some();
        let base = base.unwrap_or_default();
        let disk = repository::disk(&repo, &path)?;
        let (version, changed_text) = {
            let mut w = w.lock().unwrap();
            if !w
                .repo
                .as_ref()
                .is_some_and(|r| r.root == repo.root && r.head == repo.head)
            {
                return Err("Repository changed during inspection".into());
            }
            let d = w.documents.get_mut(&path).ok_or("Document not open")?;
            let changed = d.base != base || d.base_exists != base_exists || head != repo.head;
            d.base = base.clone();
            d.base_exists = base_exists;
            d.head = repo.head.clone();
            (d.version, changed.then(|| d.text.clone()))
        };
        let diff = changed_text.map(|text| diff::compute(&base, &text));
        Ok(Inspection {
            base,
            base_exists,
            head: repo.head.clone(),
            disk,
            version,
            diff,
        })
    })
    .await
}
#[tauri::command]
async fn resolve_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
    reload: bool,
    version: u64,
) -> Result<Resolved, String> {
    let w = state.workspace(window.label());
    work(move || {
        let r = w.lock().unwrap().repo.clone().ok_or("No repository")?;
        let disk = repository::disk(&r, &path)?;
        let mut w = w.lock().unwrap();
        let d = w.documents.get_mut(&path).ok_or("Document not open")?;
        if d.version != version {
            return Err("Document changed before reload".into());
        }
        d.disk = disk;
        if reload {
            d.text = d.disk.clone().unwrap_or_default();
            d.version += 1;
        }
        let document = d.clone();
        drop(w);
        let diff = diff::compute(&document.base, &document.text);
        Ok(Resolved { document, diff })
    })
    .await
}
#[tauri::command]
async fn save_document(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
) -> Result<Saved, String> {
    let w = state.workspace(window.label());
    work(move || {
        let (repo, mut snapshot) = {
            let w = w.lock().unwrap();
            (
                w.repo.clone().ok_or("No repository")?,
                w.documents.get(&path).ok_or("Document not open")?.clone(),
            )
        };
        repository::save(&repo, &path, &snapshot.text, &snapshot.disk)?;
        snapshot.disk = Some(snapshot.text.clone());
        w.lock()
            .unwrap()
            .documents
            .get_mut(&path)
            .ok_or("Document not open")?
            .disk = snapshot.disk.clone();
        Ok(Saved {
            disk: snapshot.disk,
        })
    })
    .await
}
#[tauri::command]
async fn stage_rows(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    path: String,
    source: Option<ReviewSource>,
) -> Result<StageSnapshot, String> {
    let w = state.workspace(window.label());
    work(move || {
        let (repo, d) = {
            let w = w.lock().unwrap();
            (
                w.repo.as_ref().ok_or("No repository")?.clone(),
                w.documents.get(&path).ok_or("Document not open")?.clone(),
            )
        };
        d.review(&repo, source)
    })
    .await
}
#[tauri::command]
async fn stage_selected(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    selection: Selection,
    index: String,
) -> Result<(), String> {
    let w = state.workspace(window.label());
    work(move || {
        let PreparedSelection { repo, entries } =
            prepare_selection(&w.lock().unwrap(), &[selection])?;
        repository::apply_selection(&repo, &index, &entries, None).map(|_| ())
    })
    .await
}
#[tauri::command]
async fn commit_changes(
    window: tauri::Window,
    state: tauri::State<'_, Service>,
    message: String,
    selections: Vec<Selection>,
    index: String,
) -> Result<repository::GitOutcome, String> {
    let w = state.workspace(window.label());
    work(move || {
        let PreparedSelection { repo, entries } =
            prepare_selection(&w.lock().unwrap(), &selections)?;
        repository::apply_selection(&repo, &index, &entries, Some(&message))
    })
    .await
}
struct PreparedSelection {
    repo: Arc<repository::Repo>,
    entries: Vec<(String, Option<String>)>,
}
fn prepare_selection(w: &Workspace, selections: &[Selection]) -> Result<PreparedSelection, String> {
    let repo = w.repo.as_ref().ok_or("No repository")?;
    let mut paths = HashSet::new();
    let mut entries = Vec::new();
    for selection in selections {
        if !paths.insert(&selection.path) {
            return Err("Duplicate selection path".into());
        }
        let d = w
            .documents
            .get(&selection.path)
            .ok_or("Document not open")?;
        if d.head != repo.head {
            return Err("HEAD changed; refresh before committing".into());
        }
        entries.push((selection.path.clone(), d.selected_entry(repo, selection)?));
    }
    Ok(PreparedSelection {
        repo: repo.clone(),
        entries,
    })
}
#[derive(Default)]
struct QuitState {
    pending: Mutex<Option<(u64, HashSet<String>)>>,
    next: std::sync::atomic::AtomicU64,
    allowed: AtomicBool,
}
fn begin_quit(app: &tauri::AppHandle) {
    let q = app.state::<QuitState>();
    let windows = app.webview_windows();
    let attempt = q.next.fetch_add(1, Ordering::SeqCst) + 1;
    {
        let mut pending = q.pending.lock().unwrap();
        if pending.is_some() {
            return;
        }
        *pending = Some((attempt, windows.keys().cloned().collect()));
    }
    if windows.is_empty() {
        q.allowed.store(true, Ordering::SeqCst);
        app.exit(0);
        return;
    }
    for w in windows.values() {
        if w.emit("request-quit", attempt).is_err() {
            *q.pending.lock().unwrap() = None;
            let _ = app.emit("quit-cancelled", attempt);
            break;
        }
    }
}
#[tauri::command]
fn frontend_ready(app: tauri::AppHandle, window: tauri::Window) -> Result<(), String> {
    let q = app.state::<QuitState>();
    let mut pending = q.pending.lock().unwrap();
    if let Some((attempt, labels)) = pending.as_mut() {
        labels.insert(window.label().to_owned());
        window
            .emit("request-quit", *attempt)
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
#[tauri::command]
fn request_quit(app: tauri::AppHandle) {
    begin_quit(&app)
}
#[tauri::command]
fn quit_response(app: tauri::AppHandle, window: tauri::Window, approved: bool, attempt: u64) {
    let q = app.state::<QuitState>();
    let mut pending = q.pending.lock().unwrap();
    if pending.as_ref().map(|(id, _)| *id) != Some(attempt) {
        return;
    }
    if !approved {
        *pending = None;
        drop(pending);
        let _ = app.emit("quit-cancelled", attempt);
        return;
    }
    if let Some((_, labels)) = pending.as_mut() {
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
    let startup = Startup {
        started: std::time::Instant::now(),
        warm: Mutex::new(WarmWindow::Unavailable),
    };
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
            take_startup_folder,
            document_path,
            resize_grid,
            route_folder,
            quick_matches,
            request_quit,
            frontend_ready,
            quit_response,
            open_folder,
            refresh,
            open_document,
            release_document,
            edit_document,
            sync_document,
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
                match build_folder_window(app, STARTUP_WINDOW, "index.html?warm=1".into()) {
                    Ok(_) => *app.state::<Startup>().warm.lock().unwrap() = WarmWindow::Idle,
                    Err(error) => eprintln!("Could not preload the editor: {error}"),
                }
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
                let q = app.state::<QuitState>();
                let mut pending = q.pending.lock().unwrap();
                if let Some((_, labels)) = pending.as_mut() {
                    labels.remove(&label);
                }
                let finished = pending
                    .as_ref()
                    .is_some_and(|(_, labels)| labels.is_empty());
                if finished {
                    *pending = None;
                    q.allowed.store(true, Ordering::SeqCst);
                }
                drop(pending);
                if finished {
                    app.exit(0);
                }
                if label == STARTUP_WINDOW {
                    *app.state::<Startup>().warm.lock().unwrap() = WarmWindow::Unavailable;
                }
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
mod regression_tests;
