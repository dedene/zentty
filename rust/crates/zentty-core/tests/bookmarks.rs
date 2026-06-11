use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use serde_json::json;
use zentty_core::bookmarks::{
    BookmarkNameSuggester, BookmarkStore, BookmarksPopoverModel, WorkspaceTemplate,
    WorkspaceTemplateCapture, WorkspaceTemplateCaptureColumn, WorkspaceTemplateCaptureInput,
    WorkspaceTemplateCapturePane, WorkspaceTemplateColumn, WorkspaceTemplateExporter,
    WorkspaceTemplateImportError, WorkspaceTemplateKind, WorkspaceTemplatePane,
    template_safe_environment_overrides,
};

#[test]
fn bookmark_store_returns_empty_when_file_missing() {
    let dir = test_directory("missing");
    let path = dir.join("bookmarks.json");

    let store = BookmarkStore::load(path).expect("store should load");

    assert!(store.templates().is_empty());
    fs::remove_dir_all(dir).ok();
}

#[test]
fn bookmark_store_returns_empty_and_preserves_corrupt_file_aside() {
    let dir = test_directory("corrupt");
    let path = dir.join("bookmarks.json");
    fs::create_dir_all(&dir).expect("test dir should be created");
    fs::write(&path, "not-json").expect("corrupt bookmark file should write");

    let store = BookmarkStore::load(path.clone()).expect("store should load corrupt file as empty");

    assert!(store.templates().is_empty());
    assert!(!path.exists());
    let siblings = fs::read_dir(&dir)
        .expect("dir should read")
        .map(|entry| entry.unwrap().file_name().to_string_lossy().to_string())
        .collect::<Vec<_>>();
    assert!(
        siblings.iter().any(|name| name.contains(".corrupt-")),
        "expected corrupt sibling, found {siblings:?}"
    );
    fs::remove_dir_all(dir).ok();
}

#[test]
fn bookmark_store_upsert_rename_pin_record_duplicate_and_delete_persist() {
    let dir = test_directory("mutations");
    let path = dir.join("bookmarks.json");
    let mut store = BookmarkStore::load(path.clone()).expect("store should load");
    let template = WorkspaceTemplate::new("Demo", WorkspaceTemplateKind::Bookmark);
    let id = template.id.clone();

    store.upsert(template).expect("upsert should persist");
    store
        .rename(&id, " Renamed ")
        .expect("rename should persist");
    store.set_pinned(&id, true).expect("pin should persist");
    store.record_use(&id).expect("record use should persist");
    let copy = store
        .duplicate(&id)
        .expect("duplicate should persist")
        .expect("copy should be created");
    let second_copy = store
        .duplicate(&id)
        .expect("second duplicate should persist")
        .expect("second copy should be created");

    assert_eq!(store.template(&id).unwrap().name, "Renamed");
    assert!(store.template(&id).unwrap().pinned);
    assert!(store.template(&id).unwrap().last_used_at.is_some());
    assert_eq!(copy.name, "Renamed copy");
    assert_eq!(second_copy.name, "Renamed copy 2");
    assert_ne!(copy.id, id);

    assert!(store.delete(&id).expect("delete should persist"));
    assert!(store.template(&id).is_none());

    let reloaded = BookmarkStore::load(path).expect("store should reload");
    assert_eq!(
        reloaded
            .templates()
            .iter()
            .map(|template| template.name.as_str())
            .collect::<Vec<_>>(),
        vec!["Renamed copy", "Renamed copy 2"]
    );
    fs::remove_dir_all(dir).ok();
}

#[test]
fn bookmark_store_upsert_preserves_symlinked_file_on_save() {
    let dir = test_directory("symlink");
    let repo_dir = dir.join("dotfiles");
    let home_dir = dir.join("home");
    fs::create_dir_all(&repo_dir).expect("repo dir should be created");
    fs::create_dir_all(&home_dir).expect("home dir should be created");
    let target = repo_dir.join("bookmarks.json");
    let link = home_dir.join("bookmarks.json");
    create_file_symlink(&target, &link).expect("test symlink should be created");

    let mut store = BookmarkStore::load(link.clone()).expect("store should load through symlink");
    store
        .upsert(WorkspaceTemplate::new(
            "Demo",
            WorkspaceTemplateKind::Bookmark,
        ))
        .expect("upsert should write symlink target");

    assert_eq!(fs::read_link(&link).expect("link should survive"), target);
    assert!(target.exists());
    let reloaded = BookmarkStore::load(link).expect("store should reload through symlink");
    assert_eq!(reloaded.templates()[0].name, "Demo");
    fs::remove_dir_all(dir).ok();
}

#[test]
fn workspace_template_matches_swift_json_field_names_and_helpers() {
    let template = template_with_environment(BTreeMap::from([
        (" PATH ".to_string(), "generated".to_string()),
        ("ZENTTY_PANE_ID".to_string(), "pane-1".to_string()),
        ("CUSTOM".to_string(), "kept".to_string()),
    ]));

    let json = serde_json::to_value(&template).expect("template should encode");

    assert_eq!(json["schemaVersion"], 1);
    assert_eq!(json["focusedColumnID"], "column-1");
    assert_eq!(json["columns"][0]["focusedPaneID"], "pane-1");
    assert_eq!(json["columns"][0]["panes"][0]["titleSeed"], "server");
    assert_eq!(template.pane_count(), 1);
    assert_eq!(template.all_panes()[0].id, "pane-1");

    let preset = template.stripping_working_directories();
    assert_eq!(preset.kind, WorkspaceTemplateKind::Preset);
    assert_eq!(preset.project_root, None);
    assert_eq!(preset.columns[0].panes[0].working_directory, None);

    let stripped = template.stripping_unsafe_environment();
    assert_eq!(
        stripped.columns[0].panes[0].environment,
        BTreeMap::from([("CUSTOM".to_string(), "kept".to_string())])
    );

    let mut pinned_template = template.clone();
    pinned_template.pinned = true;
    pinned_template.last_used_at = Some("2026-06-08T00:00:00Z".to_string());
    let preset_copy = pinned_template.fresh_preset_copy(" Demo preset ");
    assert_ne!(preset_copy.id, pinned_template.id);
    assert_eq!(preset_copy.name, "Demo preset");
    assert_eq!(preset_copy.kind, WorkspaceTemplateKind::Preset);
    assert_eq!(preset_copy.project_root, None);
    assert_eq!(preset_copy.columns[0].panes[0].working_directory, None);
    assert_eq!(
        preset_copy.columns[0].panes[0].environment,
        BTreeMap::from([("CUSTOM".to_string(), "kept".to_string())])
    );
    assert!(!preset_copy.pinned);
    assert_eq!(preset_copy.last_used_at, None);
}

#[test]
fn template_safe_environment_overrides_strips_generated_and_internal_keys() {
    let safe = template_safe_environment_overrides(&BTreeMap::from([
        ("".to_string(), "blank".to_string()),
        (" PROMPT_COMMAND ".to_string(), "generated".to_string()),
        ("ZENTTY_INSTANCE_ID".to_string(), "internal".to_string()),
        ("USER_FLAG".to_string(), "1".to_string()),
    ]));

    assert_eq!(
        safe,
        BTreeMap::from([("USER_FLAG".to_string(), "1".to_string())])
    );
}

#[test]
fn workspace_template_capture_preserves_bookmark_layout_and_sanitizes_environment() {
    let dir = test_directory("capture-bookmark");
    let project = dir.join("project");
    let api = project.join("api");
    let worker = project.join("worker");
    fs::create_dir_all(&api).expect("api dir should be created");
    fs::create_dir_all(&worker).expect("worker dir should be created");

    let template = WorkspaceTemplateCapture::capture(WorkspaceTemplateCaptureInput {
        name: " Demo ".to_string(),
        kind: WorkspaceTemplateKind::Bookmark,
        title: Some(" Restored ".to_string()),
        color: Some("teal".to_string()),
        next_pane_number: 0,
        focused_column_id: Some("column-2".to_string()),
        columns: vec![
            WorkspaceTemplateCaptureColumn {
                id: "column-1".to_string(),
                width: 520.0,
                focused_pane_id: Some("pane-1".to_string()),
                last_focused_pane_id: Some("pane-1".to_string()),
                pane_heights: vec![0.5],
                panes: vec![WorkspaceTemplateCapturePane {
                    id: "pane-1".to_string(),
                    title_seed: Some(" server ".to_string()),
                    working_directory: Some(api.to_string_lossy().to_string()),
                    command: Some(" cargo test ".to_string()),
                    environment: BTreeMap::from([
                        ("CUSTOM".to_string(), "kept".to_string()),
                        ("ZENTTY_PANE_ID".to_string(), "generated".to_string()),
                    ]),
                }],
            },
            WorkspaceTemplateCaptureColumn {
                id: "column-2".to_string(),
                width: 480.0,
                focused_pane_id: Some("pane-2".to_string()),
                last_focused_pane_id: Some("pane-2".to_string()),
                pane_heights: vec![1.0],
                panes: vec![WorkspaceTemplateCapturePane {
                    id: "pane-2".to_string(),
                    title_seed: Some(" worker ".to_string()),
                    working_directory: Some(worker.to_string_lossy().to_string()),
                    command: None,
                    environment: BTreeMap::new(),
                }],
            },
        ],
    });

    assert_eq!(template.name, "Demo");
    assert_eq!(template.kind, WorkspaceTemplateKind::Bookmark);
    assert_eq!(template.title, Some("Restored".to_string()));
    assert_eq!(template.color, Some("teal".to_string()));
    assert_eq!(
        template.project_root,
        Some(project.to_string_lossy().to_string())
    );
    assert_eq!(template.next_pane_number, 1);
    assert_eq!(template.focused_column_id, Some("column-2".to_string()));
    assert_eq!(template.columns[0].width, 520.0);
    assert_eq!(
        template.columns[0].panes[0].title_seed,
        Some("server".to_string())
    );
    assert_eq!(
        template.columns[0].panes[0].command,
        Some("cargo test".to_string())
    );
    assert_eq!(
        template.columns[0].panes[0].environment,
        BTreeMap::from([("CUSTOM".to_string(), "kept".to_string())])
    );

    fs::remove_dir_all(dir).ok();
}

#[test]
fn workspace_template_capture_strips_preset_working_directories() {
    let template = WorkspaceTemplateCapture::capture(WorkspaceTemplateCaptureInput {
        name: "Two pane".to_string(),
        kind: WorkspaceTemplateKind::Preset,
        title: None,
        color: None,
        next_pane_number: 2,
        focused_column_id: Some("column-1".to_string()),
        columns: vec![WorkspaceTemplateCaptureColumn {
            id: "column-1".to_string(),
            width: 640.0,
            focused_pane_id: Some("pane-1".to_string()),
            last_focused_pane_id: Some("pane-1".to_string()),
            pane_heights: vec![1.0],
            panes: vec![WorkspaceTemplateCapturePane {
                id: "pane-1".to_string(),
                title_seed: Some("shell".to_string()),
                working_directory: Some(r"C:\Projects\secret".to_string()),
                command: Some("npm run dev".to_string()),
                environment: BTreeMap::new(),
            }],
        }],
    });

    assert_eq!(template.kind, WorkspaceTemplateKind::Preset);
    assert_eq!(template.project_root, None);
    assert_eq!(template.columns[0].panes[0].working_directory, None);
    assert_eq!(
        template.columns[0].panes[0].command,
        Some("npm run dev".to_string())
    );
}

#[test]
fn bookmark_name_suggester_matches_bookmark_and_preset_fallbacks() {
    let dirs = vec![
        r"C:\Projects\zentty\api".to_string(),
        r"C:\Projects\zentty\worker".to_string(),
    ];
    assert_eq!(
        BookmarkNameSuggester::suggest(
            WorkspaceTemplateKind::Bookmark,
            Some("Zentty"),
            &dirs,
            None,
            2
        ),
        "Zentty"
    );
    assert_eq!(
        BookmarkNameSuggester::suggest(WorkspaceTemplateKind::Bookmark, None, &dirs, None, 2),
        "zentty"
    );
    assert_eq!(
        BookmarkNameSuggester::suggest(WorkspaceTemplateKind::Preset, None, &[], Some("node"), 2),
        "2 panes: node"
    );
    assert_eq!(
        BookmarkNameSuggester::suggest(
            WorkspaceTemplateKind::Preset,
            None,
            &[],
            Some("cmd.exe"),
            1
        ),
        "1-pane preset"
    );
}

#[test]
fn workspace_template_exporter_exports_bookmarks_as_safe_presets_and_imports_fresh_copy() {
    let template = template_with_environment(BTreeMap::from([
        ("CUSTOM".to_string(), "kept".to_string()),
        ("ZENTTY_PANE_ID".to_string(), "pane-1".to_string()),
    ]));

    let exported = WorkspaceTemplateExporter::export(&template).expect("template should export");
    let exported_json: serde_json::Value =
        serde_json::from_slice(&exported).expect("exported json should decode");
    assert_eq!(exported_json["schemaVersion"], 1);
    assert_eq!(exported_json["template"]["kind"], "preset");
    assert_eq!(
        exported_json["template"]["columns"][0]["panes"][0]["workingDirectory"],
        serde_json::Value::Null
    );
    assert_eq!(
        exported_json["template"]["columns"][0]["panes"][0]["environment"],
        json!({ "CUSTOM": "kept" })
    );

    let imported =
        WorkspaceTemplateExporter::import_template(&exported).expect("template should import");
    assert_ne!(imported.id, template.id);
    assert!(!imported.pinned);
    assert_eq!(imported.last_used_at, None);
    assert_eq!(imported.kind, WorkspaceTemplateKind::Preset);
    assert_eq!(
        imported.columns[0].panes[0].environment,
        BTreeMap::from([("CUSTOM".to_string(), "kept".to_string())])
    );
}

#[test]
fn workspace_template_exporter_writes_and_reads_preset_files() {
    let dir = test_directory("exporter-files");
    let path = dir.join(format!(
        "Demo.{}",
        WorkspaceTemplateExporter::FILE_EXTENSION
    ));
    let template = template_with_environment(BTreeMap::from([
        ("CUSTOM".to_string(), "kept".to_string()),
        ("ZENTTY_PANE_ID".to_string(), "pane-1".to_string()),
    ]));

    WorkspaceTemplateExporter::write(&template, &path).expect("template should write");
    assert!(path.exists());
    let imported = WorkspaceTemplateExporter::read(&path).expect("template should read");

    assert_ne!(imported.id, template.id);
    assert_eq!(imported.kind, WorkspaceTemplateKind::Preset);
    assert_eq!(imported.project_root, None);
    assert_eq!(imported.columns[0].panes[0].working_directory, None);
    assert_eq!(
        imported.columns[0].panes[0].environment,
        BTreeMap::from([("CUSTOM".to_string(), "kept".to_string())])
    );

    fs::remove_dir_all(dir).ok();
}

#[test]
fn workspace_template_importer_rejects_newer_export_schema() {
    let data = serde_json::to_vec(&json!({
        "schemaVersion": 999,
        "exportedAt": "2026-06-08T00:00:00Z",
        "template": WorkspaceTemplate::new("Demo", WorkspaceTemplateKind::Preset),
    }))
    .expect("json should encode");

    assert_eq!(
        WorkspaceTemplateExporter::import_template(&data),
        Err(WorkspaceTemplateImportError::SchemaVersionTooNew {
            found: 999,
            supported: 1
        })
    );
}

#[test]
fn bookmarks_popover_model_filters_groups_and_sorts_like_swift() {
    let mut pinned = WorkspaceTemplate::new("API", WorkspaceTemplateKind::Bookmark);
    pinned.pinned = true;
    pinned.project_root = Some(r"C:\Projects\api".to_string());
    let mut recent = WorkspaceTemplate::new("Docs", WorkspaceTemplateKind::Bookmark);
    recent.last_used_at = Some("2026-06-08T10:00:00Z".to_string());
    let mut older = WorkspaceTemplate::new("App", WorkspaceTemplateKind::Preset);
    older.title = Some("Application".to_string());
    older.last_used_at = Some("2026-06-07T10:00:00Z".to_string());

    let model = BookmarksPopoverModel::build(&[older.clone(), recent.clone(), pinned.clone()], "");
    assert_eq!(
        model
            .bookmarks
            .iter()
            .map(|template| template.name.as_str())
            .collect::<Vec<_>>(),
        vec!["API", "Docs"]
    );
    assert_eq!(
        model
            .presets
            .iter()
            .map(|template| template.name.as_str())
            .collect::<Vec<_>>(),
        vec!["App"]
    );
    assert!(model.has_any_templates);
    assert!(!model.is_empty_after_filtering());

    let filtered = BookmarksPopoverModel::build(&[older, recent, pinned], "application");
    assert_eq!(filtered.bookmarks.len(), 0);
    assert_eq!(filtered.presets[0].name, "App");

    let empty = BookmarksPopoverModel::build(&[], "missing");
    assert!(!empty.has_any_templates);
    assert!(empty.is_empty_after_filtering());
}

fn template_with_environment(environment: BTreeMap<String, String>) -> WorkspaceTemplate {
    let mut template = WorkspaceTemplate::new("Demo", WorkspaceTemplateKind::Bookmark);
    template.id = "11111111-1111-1111-1111-111111111111".to_string();
    template.title = Some("Project".to_string());
    template.color = Some("blue".to_string());
    template.project_root = Some(r"C:\Projects\zentty".to_string());
    template.focused_column_id = Some("column-1".to_string());
    template.columns = vec![WorkspaceTemplateColumn {
        id: "column-1".to_string(),
        width: 0.5,
        focused_pane_id: Some("pane-1".to_string()),
        last_focused_pane_id: Some("pane-1".to_string()),
        pane_heights: vec![1.0],
        panes: vec![WorkspaceTemplatePane {
            id: "pane-1".to_string(),
            title_seed: Some("server".to_string()),
            working_directory: Some(r"C:\Projects\zentty".to_string()),
            command: Some("cargo test".to_string()),
            environment,
            was_user_edited: false,
        }],
    }];
    template.pinned = true;
    template.last_used_at = Some("2026-06-08T00:00:00Z".to_string());
    template
}

fn test_directory(name: &str) -> PathBuf {
    let mut dir = std::env::temp_dir();
    dir.push(format!(
        "zentty-rust-bookmarks-{name}-{}",
        std::process::id()
    ));
    fs::remove_dir_all(&dir).ok();
    dir
}

#[cfg(windows)]
fn create_file_symlink(target: &std::path::Path, link: &std::path::Path) -> std::io::Result<()> {
    std::os::windows::fs::symlink_file(target, link)
}

#[cfg(unix)]
fn create_file_symlink(target: &std::path::Path, link: &std::path::Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}
