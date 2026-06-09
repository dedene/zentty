use std::cell::RefCell;
use std::collections::BTreeMap;

use zentty_core::task_manager::{
    TaskManagerAvailability, TaskManagerMetricFormatter, TaskManagerNetworkState,
    TaskManagerPaneRow, TaskManagerPaneRowBuilder, TaskManagerPaneSource, TaskManagerProbeSample,
    TaskManagerProcessMetric, TaskManagerProcessProbing, TaskManagerProcessRow,
    TaskManagerProcessSampler, TaskManagerProcessTree, TaskManagerRowFilter,
    TaskManagerStableSorter,
};

#[test]
fn pane_row_aggregates_processes_and_picks_hottest_child() {
    let pane = TaskManagerPaneSource {
        window_id: "window-main".to_string(),
        window_title: "Main Window".to_string(),
        worklane_id: "worklane-api".to_string(),
        worklane_title: "API".to_string(),
        pane_id: "pane-server".to_string(),
        pane_title: "Server".to_string(),
        status_text: Some("Running tests".to_string()),
        root_pid: Some(100),
        is_remote: false,
        current_working_directory: Some("/Users/peter/project".to_string()),
    };
    let process_tree = TaskManagerProcessTree {
        root_pid: 100,
        processes: vec![
            metric(100, None, "zsh", 1.0, 20_000_000),
            metric(101, Some(100), "xcodebuild", 175.0, 700_000_000),
            metric(102, Some(101), "swift-frontend", 40.0, 200_000_000),
        ],
        network_bytes_per_second: None,
    };

    let row = TaskManagerPaneRowBuilder::row(&pane, Some(&process_tree), None);

    assert_eq!(row.cpu_percent, Some(216.0));
    assert_eq!(row.memory_bytes, Some(920_000_000));
    assert_eq!(
        row.hottest_process
            .as_ref()
            .map(|process| process.name.as_str()),
        Some("xcodebuild")
    );
    assert_eq!(
        row.process_rows
            .iter()
            .map(|process| process.pid)
            .collect::<Vec<_>>(),
        vec![101, 102, 100]
    );
    assert_eq!(
        row.network_state,
        TaskManagerNetworkState::Unavailable("Unavailable".to_string())
    );
}

#[test]
fn pane_without_root_pid_stays_visible_with_reason() {
    let pane = TaskManagerPaneSource {
        window_id: "window-main".to_string(),
        window_title: "Main Window".to_string(),
        worklane_id: "worklane-api".to_string(),
        worklane_title: "API".to_string(),
        pane_id: "pane-server".to_string(),
        pane_title: "Server".to_string(),
        status_text: None,
        root_pid: None,
        is_remote: false,
        current_working_directory: Some("/Users/peter/project".to_string()),
    };

    let row = TaskManagerPaneRowBuilder::row(&pane, None, None);

    assert_eq!(
        row.availability,
        TaskManagerAvailability::Unavailable("Waiting for shell PID".to_string())
    );
    assert_eq!(row.cpu_percent, None);
    assert_eq!(row.memory_bytes, None);
}

#[test]
fn remote_pane_without_root_pid_uses_remote_reason() {
    let pane = TaskManagerPaneSource {
        is_remote: true,
        root_pid: None,
        ..pane_source("Server", "API", None, 100)
    };

    let row = TaskManagerPaneRowBuilder::row(&pane, None, None);

    assert_eq!(
        row.availability,
        TaskManagerAvailability::Unavailable("Remote pane".to_string())
    );
}

#[test]
fn unavailable_row_keeps_previous_peaks() {
    let pane = pane_source("Server", "API", None, 100);
    let previous = TaskManagerPaneRow {
        peak_cpu_percent: Some(250.0),
        peak_memory_bytes: Some(900_000_000),
        ..row("Server", "API", None, "node", 100, 10.0)
    };

    let row = TaskManagerPaneRowBuilder::row(&pane, None, Some(&previous));

    assert_eq!(row.peak_cpu_percent, Some(250.0));
    assert_eq!(row.peak_memory_bytes, Some(900_000_000));
}

#[test]
fn filter_matches_worklane_process_cwd_and_pid() {
    let rows = vec![
        row("Server", "API", Some("/repo/api"), "node", 100, 10.0),
        row("Shell", "Docs", Some("/repo/docs"), "vim", 200, 1.0),
    ];

    assert_eq!(filtered_pane_ids(&rows, "api"), vec!["Server"]);
    assert_eq!(filtered_pane_ids(&rows, "vim"), vec!["Shell"]);
    assert_eq!(filtered_pane_ids(&rows, "200"), vec!["Shell"]);
    assert_eq!(filtered_pane_ids(&rows, "repo/docs"), vec!["Shell"]);
}

#[test]
fn stable_hot_first_sort_avoids_tiny_reorders() {
    let previous_order = vec!["A".to_string(), "B".to_string()];
    let rows = vec![
        row("B", "Main", None, "node", 2, 50.1),
        row("A", "Main", None, "swift", 1, 50.0),
    ];

    let sorted = TaskManagerStableSorter::sort(&rows, &previous_order);

    assert_eq!(
        sorted
            .iter()
            .map(|row| row.pane_id.as_str())
            .collect::<Vec<_>>(),
        vec!["A", "B"]
    );
}

#[test]
fn sort_falls_back_to_memory_and_natural_title_order() {
    let rows = vec![
        TaskManagerPaneRow {
            memory_bytes: Some(100),
            ..row("Pane 10", "Main", None, "node", 10, 0.0)
        },
        TaskManagerPaneRow {
            memory_bytes: Some(200),
            ..row("Pane 2", "Main", None, "node", 2, 0.0)
        },
        TaskManagerPaneRow {
            memory_bytes: Some(100),
            ..row("Pane 3", "Main", None, "node", 3, 0.0)
        },
    ];

    let sorted = TaskManagerStableSorter::sort(&rows, &[]);

    assert_eq!(
        sorted
            .iter()
            .map(|row| row.pane_id.as_str())
            .collect::<Vec<_>>(),
        vec!["Pane 2", "Pane 3", "Pane 10"]
    );
}

#[test]
fn metric_formatter_matches_task_manager_display_contract() {
    assert_eq!(TaskManagerMetricFormatter::cpu(None), "-");
    assert_eq!(TaskManagerMetricFormatter::cpu(Some(12.345)), "12.3%");
    assert_eq!(TaskManagerMetricFormatter::memory(None), "-");
    assert_eq!(
        TaskManagerMetricFormatter::memory(Some(920_000_000)),
        "920 MB"
    );
    assert_eq!(
        TaskManagerMetricFormatter::network(&TaskManagerNetworkState::Available {
            bytes_per_second: 1_500_000,
        }),
        "1.5 MB/s"
    );
    assert_eq!(
        TaskManagerMetricFormatter::network(&TaskManagerNetworkState::Unavailable(
            "Unavailable".to_string()
        )),
        "-"
    );
}

#[test]
fn sibling_trees_keep_cpu_history_across_ticks() {
    let probe = FakeProbe::default();
    let mut sampler = TaskManagerProcessSampler::new(probe.clone());
    probe.set_trees([(100, vec![100]), (200, vec![200])]);
    probe.set_cpu_times([(100, 0), (200, 0)]);
    sampler.sample_root_pids(&[100, 200], 0.0);

    probe.set_cpu_times([(100, 1_000_000_000), (200, 1_000_000_000)]);
    let trees = sampler.sample_root_pids(&[100, 200], 1.0);

    assert_close(
        trees
            .get(&100)
            .and_then(|tree| tree.processes.first())
            .map(|process| process.cpu_percent)
            .unwrap_or(-1.0),
        100.0,
    );
    assert_close(
        trees
            .get(&200)
            .and_then(|tree| tree.processes.first())
            .map(|process| process.cpu_percent)
            .unwrap_or(-1.0),
        100.0,
    );
}

#[test]
fn partial_cpu_usage_is_proportional() {
    let probe = FakeProbe::default();
    let mut sampler = TaskManagerProcessSampler::new(probe.clone());
    probe.set_trees([(100, vec![100])]);
    probe.set_cpu_times([(100, 0)]);
    sampler.sample_root_pids(&[100], 0.0);

    probe.set_cpu_times([(100, 500_000_000)]);
    let trees = sampler.sample_root_pids(&[100], 2.0);

    assert_close(
        trees
            .get(&100)
            .and_then(|tree| tree.processes.first())
            .map(|process| process.cpu_percent)
            .unwrap_or(-1.0),
        25.0,
    );
}

#[test]
fn dead_pids_are_pruned_from_history() {
    let probe = FakeProbe::default();
    let mut sampler = TaskManagerProcessSampler::new(probe.clone());
    probe.set_trees([(100, vec![100, 101])]);
    probe.set_cpu_times([(100, 0), (101, 0)]);
    sampler.sample_root_pids(&[100], 0.0);

    probe.set_trees([(100, vec![100])]);
    probe.set_cpu_times([(100, 250_000_000)]);
    let trees = sampler.sample_root_pids(&[100], 1.0);

    let tree = trees.get(&100).expect("tree should exist");
    assert_eq!(
        tree.processes
            .iter()
            .map(|process| process.pid)
            .collect::<Vec<_>>(),
        vec![100]
    );
    assert_close(tree.processes[0].cpu_percent, 25.0);
}

#[test]
fn first_sample_reports_zero_without_history() {
    let probe = FakeProbe::default();
    let mut sampler = TaskManagerProcessSampler::new(probe.clone());
    probe.set_trees([(100, vec![100])]);
    probe.set_cpu_times([(100, 999_000_000)]);

    let trees = sampler.sample_root_pids(&[100], 0.0);

    assert_eq!(trees[&100].processes[0].cpu_percent, 0.0);
}

#[test]
fn single_tree_convenience_returns_matching_tree() {
    let probe = FakeProbe::default();
    let mut sampler = TaskManagerProcessSampler::new(probe.clone());
    probe.set_trees([(100, vec![100, 101])]);
    probe.set_cpu_times([(100, 0), (101, 0)]);

    let tree = sampler
        .sample_root_pid(100, 0.0)
        .expect("tree should exist");

    assert_eq!(tree.root_pid, 100);
    let mut pids = tree
        .processes
        .iter()
        .map(|process| process.pid)
        .collect::<Vec<_>>();
    pids.sort();
    assert_eq!(pids, vec![100, 101]);
}

#[test]
fn single_tree_convenience_rejects_nonpositive_root() {
    let probe = FakeProbe::default();
    let mut sampler = TaskManagerProcessSampler::new(probe);

    assert_eq!(sampler.sample_root_pid(0, 0.0), None);
    assert_eq!(sampler.sample_root_pid(-1, 0.0), None);
}

fn metric(
    pid: i32,
    parent_pid: Option<i32>,
    name: &str,
    cpu_percent: f64,
    memory_bytes: u64,
) -> TaskManagerProcessMetric {
    TaskManagerProcessMetric {
        pid,
        parent_pid,
        name: name.to_string(),
        cpu_percent,
        memory_bytes,
    }
}

fn pane_source(
    pane_title: &str,
    worklane_title: &str,
    cwd: Option<&str>,
    pid: i32,
) -> TaskManagerPaneSource {
    TaskManagerPaneSource {
        window_id: "window".to_string(),
        window_title: "Window".to_string(),
        worklane_id: worklane_title.to_string(),
        worklane_title: worklane_title.to_string(),
        pane_id: pane_title.to_string(),
        pane_title: pane_title.to_string(),
        status_text: None,
        root_pid: Some(pid),
        is_remote: false,
        current_working_directory: cwd.map(str::to_string),
    }
}

fn row(
    pane_title: &str,
    worklane_title: &str,
    cwd: Option<&str>,
    process: &str,
    pid: i32,
    cpu: f64,
) -> TaskManagerPaneRow {
    TaskManagerPaneRow {
        window_id: "window".to_string(),
        window_title: "Window".to_string(),
        worklane_id: worklane_title.to_string(),
        worklane_title: worklane_title.to_string(),
        pane_id: pane_title.to_string(),
        pane_title: pane_title.to_string(),
        status_text: None,
        current_working_directory: cwd.map(str::to_string),
        root_pid: Some(pid),
        availability: TaskManagerAvailability::Available,
        cpu_percent: Some(cpu),
        peak_cpu_percent: Some(cpu),
        memory_bytes: Some(100),
        peak_memory_bytes: Some(100),
        network_state: TaskManagerNetworkState::Unavailable("Unavailable".to_string()),
        hottest_process: Some(TaskManagerProcessRow {
            pid,
            parent_pid: None,
            name: process.to_string(),
            cpu_percent: cpu,
            memory_bytes: 100,
        }),
        process_rows: vec![TaskManagerProcessRow {
            pid,
            parent_pid: None,
            name: process.to_string(),
            cpu_percent: cpu,
            memory_bytes: 100,
        }],
        is_remote: false,
    }
}

fn filtered_pane_ids(rows: &[TaskManagerPaneRow], query: &str) -> Vec<String> {
    TaskManagerRowFilter::filter(rows, query)
        .into_iter()
        .map(|row| row.pane_id.clone())
        .collect()
}

fn assert_close(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() <= 0.001,
        "expected {actual} to be within 0.001 of {expected}"
    );
}

#[derive(Clone, Default)]
struct FakeProbe {
    trees: std::rc::Rc<RefCell<BTreeMap<i32, Vec<i32>>>>,
    cpu_time: std::rc::Rc<RefCell<BTreeMap<i32, u64>>>,
}

impl FakeProbe {
    fn set_trees<I>(&self, trees: I)
    where
        I: IntoIterator<Item = (i32, Vec<i32>)>,
    {
        *self.trees.borrow_mut() = trees.into_iter().collect();
    }

    fn set_cpu_times<I>(&self, cpu_times: I)
    where
        I: IntoIterator<Item = (i32, u64)>,
    {
        *self.cpu_time.borrow_mut() = cpu_times.into_iter().collect();
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
        Some(TaskManagerProbeSample {
            cpu_time_nanoseconds: *self.cpu_time.borrow().get(&pid)?,
            parent_pid: None,
            name: format!("process-{pid}"),
            memory_bytes: 1_000_000,
        })
    }
}
