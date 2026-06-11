use zentty_core::command_palette::{
    TaskRunnerAction, TaskRunnerDisabledReason, TaskRunnerSourceKind,
};
use zentty_core::task_runner::{
    TaskRunnerExecutionPlan, TaskRunnerExecutionPlanner, TaskRunnerFocusedPaneState,
    TaskRunnerShellActivityState,
};

#[test]
fn task_runner_execution_policy_matches_swift_idle_prompt_rules() {
    let action = task_runner_action("pnpm run dev", None);
    let idle_focused = TaskRunnerFocusedPaneState {
        pane_id: "pane-main".to_string(),
        runtime_available: true,
        shell_activity_state: TaskRunnerShellActivityState::PromptIdle,
        terminal_progress_indicates_activity: false,
    };

    assert_eq!(
        TaskRunnerExecutionPlanner::plan(&action, Some(&idle_focused)),
        TaskRunnerExecutionPlan::FocusedPane {
            pane_id: "pane-main".to_string(),
            command: "pnpm run dev".to_string(),
        }
    );

    for shell_activity_state in [
        TaskRunnerShellActivityState::CommandRunning,
        TaskRunnerShellActivityState::Unknown,
    ] {
        let context = TaskRunnerFocusedPaneState {
            shell_activity_state,
            ..idle_focused.clone()
        };
        assert_eq!(
            TaskRunnerExecutionPlanner::plan(&action, Some(&context)),
            TaskRunnerExecutionPlan::NewPane {
                command: "pnpm run dev".to_string(),
                working_directory: "C:\\Projects\\zentty".to_string(),
                environment: Default::default(),
            }
        );
    }

    let active_progress = TaskRunnerFocusedPaneState {
        terminal_progress_indicates_activity: true,
        ..idle_focused.clone()
    };
    assert_eq!(
        TaskRunnerExecutionPlanner::plan(&action, Some(&active_progress)),
        TaskRunnerExecutionPlan::NewPane {
            command: "pnpm run dev".to_string(),
            working_directory: "C:\\Projects\\zentty".to_string(),
            environment: Default::default(),
        }
    );

    let with_environment =
        task_runner_action("npm run build", None).with_environment("NODE_ENV", "production");
    assert_eq!(
        TaskRunnerExecutionPlanner::plan(&with_environment, Some(&idle_focused)),
        TaskRunnerExecutionPlan::NewPane {
            command: "npm run build".to_string(),
            working_directory: "C:\\Projects\\zentty".to_string(),
            environment: [("NODE_ENV".to_string(), "production".to_string())].into(),
        }
    );
}

#[test]
fn disabled_task_runner_execution_opens_source() {
    let action = task_runner_action(
        "task deploy",
        Some(TaskRunnerDisabledReason::unsupported(
            "Task requires variables: TARGET",
        )),
    );

    assert_eq!(
        TaskRunnerExecutionPlanner::plan(&action, None),
        TaskRunnerExecutionPlan::OpenSource {
            source_path: "C:\\Projects\\zentty\\Taskfile.yml".to_string(),
        }
    );
}

fn task_runner_action(
    command: &str,
    disabled_reason: Option<TaskRunnerDisabledReason>,
) -> TaskRunnerAction {
    TaskRunnerAction::new(
        "taskfile|C:\\Projects\\zentty\\Taskfile.yml|deploy",
        "deploy",
        None,
        TaskRunnerSourceKind::Taskfile,
        "C:\\Projects\\zentty\\Taskfile.yml",
        command,
        disabled_reason,
    )
    .with_source_root("C:\\Projects\\zentty")
    .with_working_directory("C:\\Projects\\zentty")
}
