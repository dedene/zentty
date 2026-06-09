use std::fs;
use std::path::PathBuf;

use zentty_core::command_palette::{TaskRunnerDisabledReason, TaskRunnerSourceKind};
use zentty_core::task_runner::TaskRunnerDiscoveryService;

#[test]
fn discovers_package_scripts_from_focused_working_directory_ancestry() {
    let root = test_directory("package-ancestry");
    let repo = root.join("repo");
    fs::create_dir_all(repo.join("apps/web/src")).expect("repo directories should be created");
    fs::create_dir(repo.join(".git")).expect("git marker should be created");
    fs::write(
        repo.join("package.json"),
        r#"{
          "packageManager": "pnpm@10.0.0",
          "scripts": {
            "test": "vitest",
            "dev": "vite --host 0.0.0.0"
          }
        }"#,
    )
    .expect("package.json should be written");

    let service = TaskRunnerDiscoveryService::new();
    let actions = service.discover(repo.join("apps/web/src"));

    assert_eq!(
        actions
            .iter()
            .map(|action| action.title.as_str())
            .collect::<Vec<_>>(),
        vec!["dev", "test"]
    );
    assert_eq!(
        actions
            .iter()
            .map(|action| action.source_kind)
            .collect::<Vec<_>>(),
        vec![
            TaskRunnerSourceKind::PackageScript,
            TaskRunnerSourceKind::PackageScript,
        ]
    );
    assert_eq!(
        actions
            .iter()
            .map(|action| action.execution_command.as_str())
            .collect::<Vec<_>>(),
        vec!["pnpm run dev", "pnpm run test"]
    );
    assert_eq!(
        actions
            .iter()
            .map(|action| action.working_directory.clone())
            .collect::<Vec<_>>(),
        vec![
            repo.to_string_lossy().to_string(),
            repo.to_string_lossy().to_string()
        ]
    );
    assert!(
        actions
            .iter()
            .all(|action| action.disabled_reason.is_none())
    );
    assert_eq!(actions[0].subtitle(), "package.json \u{2022} pnpm run dev");

    fs::remove_dir_all(root).ok();
}

#[test]
fn malformed_nearest_package_does_not_hide_parent_package_scripts() {
    let root = test_directory("package-malformed-child");
    let repo = root.join("repo");
    let app = repo.join("app");
    fs::create_dir_all(&app).expect("app directory should be created");
    fs::write(
        repo.join("package.json"),
        r#"{ "scripts": { "test": "root-test" } }"#,
    )
    .expect("parent package should be written");
    fs::write(app.join("package.json"), "{ invalid json").expect("child package should be written");

    let service = TaskRunnerDiscoveryService::new();
    let actions = service.discover(&app);

    assert_eq!(actions.len(), 1);
    assert_eq!(actions[0].title, "test");
    assert_eq!(
        actions[0].source_path,
        repo.join("package.json").to_string_lossy().to_string()
    );

    fs::remove_dir_all(root).ok();
}

#[test]
fn discovers_taskfile_tasks_and_local_static_includes() {
    let root = test_directory("taskfile-includes");
    let repo = root.join("repo");
    fs::create_dir_all(repo.join("tasks")).expect("task directories should be created");
    fs::write(
        repo.join("Taskfile.yml"),
        r#"version: '3'
includes:
  api: ./tasks/api.yml
  web:
    taskfile: ./tasks/web.yml
tasks:
  build:
    desc: Build everything
    cmds:
      - go build ./...
  prompt:
    requires:
      vars:
        - NAME
    cmds:
      - echo "{{.NAME}}"
"#,
    )
    .expect("root Taskfile should be written");
    fs::write(
        repo.join("tasks/api.yml"),
        r#"version: '3'
tasks:
  test:
    desc: Run API tests
    cmds:
      - go test ./...
"#,
    )
    .expect("api Taskfile should be written");
    fs::write(
        repo.join("tasks/web.yml"),
        r#"version: '3'
tasks:
  check:
    desc: Run web checks
    cmds:
      - pnpm check
"#,
    )
    .expect("web Taskfile should be written");

    let service = TaskRunnerDiscoveryService::new();
    let actions = service.discover(&repo);

    assert_eq!(
        actions
            .iter()
            .map(|action| action.title.as_str())
            .collect::<Vec<_>>(),
        vec!["build", "prompt", "api:test", "web:check"]
    );
    assert_eq!(
        actions
            .iter()
            .map(|action| action.execution_command.as_str())
            .collect::<Vec<_>>(),
        vec![
            "task build",
            "task prompt",
            "task api:test",
            "task web:check"
        ]
    );
    assert_eq!(actions[0].description.as_deref(), Some("Build everything"));
    assert_eq!(
        actions[1].disabled_reason,
        Some(TaskRunnerDisabledReason::unsupported(
            "Task requires variables: NAME"
        ))
    );
    assert_eq!(actions[2].description.as_deref(), Some("Run API tests"));
    assert_eq!(actions[3].description.as_deref(), Some("Run web checks"));

    fs::remove_dir_all(root).ok();
}

#[test]
fn discovers_vscode_tasks_with_windows_overrides_and_disables_unsupported_variables() {
    let root = test_directory("vscode-tasks");
    let repo = root.join("repo");
    let vscode = repo.join(".vscode");
    fs::create_dir_all(&vscode).expect("vscode directory should be created");
    fs::write(
        vscode.join("tasks.json"),
        r#"{
          // JSONC is accepted.
          "version": "2.0.0",
          "tasks": [
            {
              "label": "lint",
              "type": "shell",
              "command": "npm",
              "args": ["run", "lint:strict mode"],
              "options": { "env": { "NODE_ENV": "test" } },
              "windows": { "command": "pnpm", "args": ["lint:strict mode"] }
            },
            {
              "label": "lint",
              "type": "shell",
              "command": "pnpm",
              "args": ["lint:fix"]
            },
            {
              "label": "open-file",
              "type": "shell",
              "command": "cat ${file}"
            },
          ]
        }"#,
    )
    .expect("tasks.json should be written");

    let service = TaskRunnerDiscoveryService::new();
    let actions = service.discover(&repo);

    assert_eq!(
        actions
            .iter()
            .map(|action| action.title.as_str())
            .collect::<Vec<_>>(),
        vec!["lint", "lint", "open-file"]
    );
    assert_eq!(actions[0].execution_command, "pnpm 'lint:strict mode'");
    assert_eq!(
        actions[0].environment.get("NODE_ENV").map(String::as_str),
        Some("test")
    );
    assert_eq!(actions[1].execution_command, "pnpm lint:fix");
    assert_ne!(actions[0].id, actions[1].id);
    assert_eq!(
        actions[2].disabled_reason,
        Some(TaskRunnerDisabledReason::unsupported(
            "Unsupported VS Code variable: ${file}"
        ))
    );

    fs::remove_dir_all(root).ok();
}

#[test]
fn discovers_just_make_and_mise_tasks() {
    let root = test_directory("just-make-mise");
    let repo = root.join("repo");
    fs::create_dir_all(repo.join("mise-tasks")).expect("mise task directory should be created");
    fs::create_dir_all(repo.join(".mise/tasks")).expect("mise hidden task directory should exist");
    fs::write(
        repo.join("justfile"),
        r#"# Public recipe
test:
  swift test

deploy target:
  ./deploy {{target}}
"#,
    )
    .expect("justfile should be written");
    fs::write(
        repo.join("Makefile"),
        ".PHONY: build clean\nbuild: ## Build app\n\tswift build\ninternal.o: internal.c\n",
    )
    .expect("Makefile should be written");
    fs::write(
        repo.join("mise.toml"),
        r#"[tasks.lint]
description = "Lint sources"
run = "swiftlint"

[tasks]
fmt = "swiftformat ."
"#,
    )
    .expect("mise.toml should be written");
    fs::write(
        repo.join("mise-tasks/dev"),
        "#!/usr/bin/env bash\necho dev\n",
    )
    .expect("mise task should be written");
    fs::write(
        repo.join(".mise/tasks/ship"),
        "#!/usr/bin/env bash\necho ship\n",
    )
    .expect("hidden mise task should be written");

    let service = TaskRunnerDiscoveryService::new();
    let actions = service.discover(&repo);
    let summary = actions
        .iter()
        .map(|action| {
            let disabled = match &action.disabled_reason {
                Some(TaskRunnerDisabledReason::Unsupported(reason)) => reason.as_str(),
                None => "",
            };
            format!(
                "{}:{}:{}:{}",
                action.source_kind.raw_value(),
                action.title,
                action.execution_command,
                disabled
            )
        })
        .collect::<Vec<_>>();

    assert_eq!(
        summary,
        vec![
            "justfile:test:just test:",
            "justfile:deploy:just deploy:Task requires parameters: target",
            "makefile:build:make build:",
            "makefile:clean:make clean:",
            "mise:lint:mise run lint:",
            "mise:fmt:mise run fmt:",
            "mise:dev:mise run dev:",
            "mise:ship:mise run ship:",
        ]
    );

    fs::remove_dir_all(root).ok();
}

fn test_directory(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "zentty-task-runner-discovery-{name}-{}",
        std::process::id()
    ));
    fs::remove_dir_all(&dir).ok();
    fs::create_dir_all(&dir).expect("test directory should be created");
    dir
}
