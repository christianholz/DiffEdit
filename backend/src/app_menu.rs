use std::{collections::HashMap, path::PathBuf, sync::Mutex};
use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu},
    Manager,
};

pub struct Controls {
    items: Vec<MenuItem<tauri::Wry>>,
    recent: Submenu<tauri::Wry>,
    history: Mutex<Vec<String>>,
    history_file: Mutex<Option<PathBuf>>,
    wrap: CheckMenuItem<tauri::Wry>,
    whitespace: CheckMenuItem<tauri::Wry>,
}
fn section(
    app: &tauri::AppHandle,
    title: &str,
    items: &[(&str, &str, Option<&str>)],
) -> tauri::Result<Submenu<tauri::Wry>> {
    let menu = Submenu::new(app, title, true)?;
    for (id, text, key) in items {
        menu.append(&MenuItem::with_id(
            app,
            *id,
            *text,
            matches!(*id, "open" | "quit"),
            *key,
        )?)?;
    }
    Ok(menu)
}
pub fn build(app: &tauri::AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let application = section(
        app,
        "DiffEdit",
        &[("quit", "Quit DiffEdit", Some("CmdOrCtrl+Q"))],
    )?;
    let file = section(
        app,
        "File",
        &[
            ("open", "Open Folder…", Some("CmdOrCtrl+O")),
            ("save", "Save", Some("CmdOrCtrl+S")),
            ("save-all", "Save All", Some("CmdOrCtrl+Shift+S")),
            ("close", "Close Window", Some("CmdOrCtrl+W")),
        ],
    )?;
    let recent = Submenu::new(app, "Open Recent", true)?;
    file.insert(&recent, 1)?;
    let edit = section(
        app,
        "Edit",
        &[
            ("undo", "Undo", Some("CmdOrCtrl+Z")),
            ("redo", "Redo", Some("CmdOrCtrl+Shift+Z")),
            ("find", "Find…", Some("CmdOrCtrl+F")),
            ("replace", "Replace…", Some("CmdOrCtrl+Alt+F")),
            ("find-next", "Find Next", Some("CmdOrCtrl+G")),
            ("find-prev", "Find Previous", Some("CmdOrCtrl+Shift+G")),
        ],
    )?;
    let restore = MenuItem::with_id(
        app,
        "restore",
        "Restore previous",
        false,
        Some("CmdOrCtrl+D"),
    )?;
    edit.append(&restore)?;
    edit.append_items(&[
        &PredefinedMenuItem::cut(app, None)?,
        &PredefinedMenuItem::copy(app, None)?,
        &PredefinedMenuItem::paste(app, None)?,
        &PredefinedMenuItem::select_all(app, None)?,
    ])?;
    let view = Submenu::new(app, "View", true)?;
    let wrap = CheckMenuItem::with_id(
        app,
        "wrap",
        "Word Wrap",
        false,
        true,
        Some("CmdOrCtrl+Alt+W"),
    )?;
    let whitespace = CheckMenuItem::with_id(
        app,
        "whitespace",
        "Highlight Whitespace Changes",
        false,
        false,
        None::<&str>,
    )?;
    view.append_items(&[&wrap, &whitespace])?;
    for (id, text, key) in [
        ("larger", "Increase Type Size", Some("CmdOrCtrl+=")),
        ("smaller", "Decrease Type Size", Some("CmdOrCtrl+-")),
        ("mode", "Edit / Stage & Commit", None),
    ] {
        view.append(&MenuItem::with_id(app, id, text, false, key)?)?;
    }
    let go = section(
        app,
        "Go",
        &[
            ("quick", "Quick Open…", Some("CmdOrCtrl+T")),
            ("next", "Next Change", Some("CmdOrCtrl+Alt+]")),
            ("prev", "Previous Change", Some("CmdOrCtrl+Alt+[")),
            ("next-file", "Next Changed File", Some("CmdOrCtrl+Shift+]")),
            (
                "prev-file",
                "Previous Changed File",
                Some("CmdOrCtrl+Shift+["),
            ),
            ("next-group", "Next Changed Group", Some("Ctrl+Period")),
            ("prev-group", "Previous Changed Group", Some("Ctrl+Comma")),
            ("next-line", "Next Changed Line", Some("CmdOrCtrl+]")),
            ("prev-line", "Previous Changed Line", Some("CmdOrCtrl+[")),
            ("next-paragraph", "Next Paragraph", None),
            ("prev-paragraph", "Previous Paragraph", None),
        ],
    )?;
    let window = Submenu::with_items(
        app,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(app, None)?,
            &PredefinedMenuItem::maximize(app, None)?,
            &PredefinedMenuItem::bring_all_to_front(app, None)?,
        ],
    )?;
    let menu = Menu::with_items(app, &[&application, &file, &edit, &view, &go, &window])?;
    fn collect(
        menu: Vec<tauri::menu::MenuItemKind<tauri::Wry>>,
        out: &mut Vec<MenuItem<tauri::Wry>>,
    ) -> tauri::Result<()> {
        for item in menu {
            if let Some(normal) = item.as_menuitem() {
                out.push(normal.clone());
            }
            if let Some(sub) = item.as_submenu() {
                collect(sub.items()?, out)?;
            }
        }
        Ok(())
    }
    let mut items = Vec::new();
    collect(menu.items()?, &mut items)?;
    app.manage(Controls {
        items,
        recent,
        history: Mutex::new(Vec::new()),
        history_file: Mutex::new(None),
        wrap,
        whitespace,
    });
    app.state::<Controls>().render_recent(app)?;
    Ok(menu)
}
impl Controls {
    // PathResolver is not managed yet while Builder::menu is constructing menus.
    // Setup runs after Tauri has initialized its path services.
    pub fn initialize_recent(&self, app: &tauri::AppHandle) -> tauri::Result<()> {
        let file = app.path().app_data_dir()?.join("recent-folders.json");
        let history = std::fs::read(&file)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        *self.history_file.lock().unwrap() = Some(file);
        *self.history.lock().unwrap() = history;
        self.render_recent(app)
    }
    fn render_recent(&self, app: &tauri::AppHandle) -> tauri::Result<()> {
        let history = self.history.lock().unwrap();
        self.render_paths(app, &history)
    }
    fn render_paths(&self, app: &tauri::AppHandle, paths: &[String]) -> tauri::Result<()> {
        for item in self.recent.items()? {
            self.recent.remove(&item)?;
        }
        for path in paths.iter().take(10) {
            self.recent.append(&MenuItem::with_id(
                app,
                format!("recent:{path}"),
                recent_label(path),
                true,
                None::<&str>,
            )?)?;
        }
        self.recent.append(&PredefinedMenuItem::separator(app)?)?;
        self.recent.append(&MenuItem::with_id(
            app,
            "clear-recent",
            "Clear list",
            !paths.is_empty(),
            None::<&str>,
        )?)?;
        Ok(())
    }
    pub fn update_recent(
        &self,
        app: &tauri::AppHandle,
        root: Option<String>,
    ) -> Result<(), String> {
        let mut history = self.history.lock().unwrap();
        let mut paths = history.clone();
        if let Some(root) = root {
            paths.retain(|p| p != &root);
            paths.insert(0, root);
            paths.truncate(10);
        } else {
            paths.clear();
        }
        let history_file = self
            .history_file
            .lock()
            .unwrap()
            .clone()
            .ok_or("Recent folders are not initialized")?;
        std::fs::create_dir_all(history_file.parent().unwrap()).map_err(|e| e.to_string())?;
        let temp = history_file.with_extension("tmp");
        std::fs::write(
            &temp,
            serde_json::to_vec(&paths).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        std::fs::rename(temp, &history_file).map_err(|e| e.to_string())?;
        self.render_paths(app, &paths).map_err(|e| e.to_string())?;
        *history = paths;
        Ok(())
    }

    pub fn idle(&self) {
        for item in &self.items {
            let _ = item.set_enabled(matches!(item.id().as_ref(), "open" | "quit"));
        }
        let _ = self.wrap.set_enabled(false);
        let _ = self.whitespace.set_enabled(false);
    }
}
#[tauri::command]
pub fn menu_state(
    window: tauri::Window,
    controls: tauri::State<'_, Controls>,
    enabled: HashMap<String, bool>,
    wrap: bool,
    whitespace: bool,
) -> Result<(), String> {
    if !window.is_focused().unwrap_or(false) {
        return Ok(());
    }
    for item in &controls.items {
        let enable = enabled.get(item.id().as_ref()).copied().unwrap_or(false);
        if item.is_enabled().map_err(|e| e.to_string())? != enable {
            item.set_enabled(enable).map_err(|e| e.to_string())?;
        }
    }
    controls
        .wrap
        .set_enabled(*enabled.get("wrap").unwrap_or(&false))
        .map_err(|e| e.to_string())?;
    controls
        .whitespace
        .set_enabled(*enabled.get("whitespace").unwrap_or(&false))
        .map_err(|e| e.to_string())?;
    controls.wrap.set_checked(wrap).map_err(|e| e.to_string())?;
    controls
        .whitespace
        .set_checked(whitespace)
        .map_err(|e| e.to_string())
}

fn recent_label(path: &str) -> String {
    if path.chars().count() <= 70 {
        return path.to_owned();
    }
    let parts: Vec<_> = path.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() <= 4 {
        return path.to_owned();
    }
    format!(
        "/{}/{}/…/{}/{}",
        parts[0],
        parts[1],
        parts[parts.len() - 2],
        parts[parts.len() - 1]
    )
}
#[tauri::command]
pub async fn remember_folder(app: tauri::AppHandle, root: String) -> Result<(), String> {
    crate::work(move || app.state::<Controls>().update_recent(&app, Some(root))).await
}
