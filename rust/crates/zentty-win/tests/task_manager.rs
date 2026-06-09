use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use zentty_core::task_manager::{
    TaskManagerAvailability, TaskManagerPaneSource, TaskManagerProbeSample,
    TaskManagerProcessProbing,
};
use zentty_win::task_manager::{
    DesktopTaskManagerState, DesktopTaskManagerTextSnapshot, WindowsTaskManagerProcessProbe,
};

#[test]
fn desktop_task_manager_state_builds_sorted_text_snapshot_from_process_samples() {
    let probe = FakeProbe::default();
    probe.set_tree(100, vec![100, 101]);
    probe.set_sample(100, sample(0, None, "shell.exe", 1024));
    probe.set_sample(101, sample(0, Some(100), "helper.exe", 2048));

    let mut state = DesktopTaskManagerState::new(probe.clone());
    let sources = vec![
        source("pane-a", "Pane A", Some(100), Some("Running")),
        source("pane-b", "Pane B", None, None),
    ];
    let _ = state.snapshot(&sources, 0.0);

    probe.set_sample(100, sample(1_000_000_000, None, "shell.exe", 1024));
    probe.set_sample(101, sample(500_000_000, Some(100), "helper.exe", 2048));
    let snapshot = state.snapshot(&sources, 1.0);

    assert_eq!(snapshot.rows.len(), 2);
    assert_eq!(snapshot.rows[0].pane_id, "pane-a");
    assert_eq!(
        snapshot.rows[0].availability,
        TaskManagerAvailability::Available
    );
    assert_eq!(snapshot.rows[0].cpu_percent, Some(150.0));
    assert_eq!(snapshot.rows[0].memory_bytes, Some(3072));
    assert_eq!(snapshot.rows[0].hottest_process.as_ref().unwrap().pid, 100);
    assert_eq!(
        snapshot.rows[1].availability,
        TaskManagerAvailability::Unavailable("Waiting for shell PID".to_string())
    );

    let text = DesktopTaskManagerTextSnapshot::from_snapshot(&snapshot);
    let rendered = text.lines.join("\n");
    assert!(rendered.contains("Task Manager"));
    assert!(rendered.contains("Pane A"));
    assert!(rendered.contains("150.0%"));
    assert!(rendered.contains("3.1 KB"));
    assert!(rendered.contains("shell.exe (100)"));
    assert!(rendered.contains("helper.exe (101) parent 100"));
    assert!(rendered.contains("Waiting for shell PID"));
}

#[test]
#[cfg(windows)]
fn windows_process_probe_samples_current_process() {
    let probe = WindowsTaskManagerProcessProbe::new();
    let pid = i32::try_from(std::process::id()).expect("current pid should fit i32");

    let tree_pids = probe.tree_pids(pid);
    assert_eq!(tree_pids.first(), Some(&pid));

    let sample = probe
        .sample(pid)
        .expect("current process should be sampleable");
    assert!(!sample.name.trim().is_empty());
    assert!(sample.memory_bytes > 0);
}

#[derive(Clone, Default)]
struct FakeProbe {
    trees: Rc<RefCell<BTreeMap<i32, Vec<i32>>>>,
    samples: Rc<RefCell<BTreeMap<i32, TaskManagerProbeSample>>>,
}

impl FakeProbe {
    fn set_tree(&self, root_pid: i32, pids: Vec<i32>) {
        self.trees.borrow_mut().insert(root_pid, pids);
    }

    fn set_sample(&self, pid: i32, sample: TaskManagerProbeSample) {
        self.samples.borrow_mut().insert(pid, sample);
    }
}

impl TaskManagerProcessProbing for FakeProbe {
    fn tree_pids(&self, root_pid: i32) -> Vec<i32> {
        self.trees
            .borrow()
            .get(&root_pid)
            .cloned()
            .unwrap_or_default()
    }

    fn sample(&self, pid: i32) -> Option<TaskManagerProbeSample> {
        self.samples.borrow().get(&pid).cloned()
    }
}

fn source(
    pane_id: &str,
    pane_title: &str,
    root_pid: Option<i32>,
    status_text: Option<&str>,
) -> TaskManagerPaneSource {
    TaskManagerPaneSource {
        window_id: "window-main".to_string(),
        window_title: "Window 1".to_string(),
        worklane_id: "main".to_string(),
        worklane_title: "Main".to_string(),
        pane_id: pane_id.to_string(),
        pane_title: pane_title.to_string(),
        status_text: status_text.map(str::to_string),
        root_pid,
        is_remote: false,
        current_working_directory: Some(r"C:\Projects\zentty".to_string()),
    }
}

fn sample(
    cpu_time_nanoseconds: u64,
    parent_pid: Option<i32>,
    name: &str,
    memory_bytes: u64,
) -> TaskManagerProbeSample {
    TaskManagerProbeSample {
        cpu_time_nanoseconds,
        parent_pid,
        name: name.to_string(),
        memory_bytes,
    }
}
