use std::cmp::Ordering;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TaskManagerAvailability {
    Available,
    Unavailable(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TaskManagerNetworkState {
    Available { bytes_per_second: u64 },
    Unavailable(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskManagerPaneSource {
    pub window_id: String,
    pub window_title: String,
    pub worklane_id: String,
    pub worklane_title: String,
    pub pane_id: String,
    pub pane_title: String,
    pub status_text: Option<String>,
    pub root_pid: Option<i32>,
    pub is_remote: bool,
    pub current_working_directory: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TaskManagerProcessMetric {
    pub pid: i32,
    pub parent_pid: Option<i32>,
    pub name: String,
    pub cpu_percent: f64,
    pub memory_bytes: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TaskManagerProcessTree {
    pub root_pid: i32,
    pub processes: Vec<TaskManagerProcessMetric>,
    pub network_bytes_per_second: Option<u64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TaskManagerProcessRow {
    pub pid: i32,
    pub parent_pid: Option<i32>,
    pub name: String,
    pub cpu_percent: f64,
    pub memory_bytes: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TaskManagerPaneRow {
    pub window_id: String,
    pub window_title: String,
    pub worklane_id: String,
    pub worklane_title: String,
    pub pane_id: String,
    pub pane_title: String,
    pub status_text: Option<String>,
    pub current_working_directory: Option<String>,
    pub root_pid: Option<i32>,
    pub availability: TaskManagerAvailability,
    pub cpu_percent: Option<f64>,
    pub peak_cpu_percent: Option<f64>,
    pub memory_bytes: Option<u64>,
    pub peak_memory_bytes: Option<u64>,
    pub network_state: TaskManagerNetworkState,
    pub hottest_process: Option<TaskManagerProcessRow>,
    pub process_rows: Vec<TaskManagerProcessRow>,
    pub is_remote: bool,
}

pub struct TaskManagerPaneRowBuilder;

impl TaskManagerPaneRowBuilder {
    pub fn row(
        pane: &TaskManagerPaneSource,
        process_tree: Option<&TaskManagerProcessTree>,
        previous_row: Option<&TaskManagerPaneRow>,
    ) -> TaskManagerPaneRow {
        if pane.root_pid.is_none() {
            let reason = if pane.is_remote {
                "Remote pane"
            } else {
                "Waiting for shell PID"
            };
            return Self::unavailable_row(pane, reason, previous_row);
        }

        let Some(process_tree) = process_tree else {
            return Self::unavailable_row(pane, "Metrics unavailable", previous_row);
        };
        if process_tree.processes.is_empty() {
            return Self::unavailable_row(pane, "Metrics unavailable", previous_row);
        }

        let mut process_rows = process_tree
            .processes
            .iter()
            .map(|process| TaskManagerProcessRow {
                pid: process.pid,
                parent_pid: process.parent_pid,
                name: process.name.clone(),
                cpu_percent: process.cpu_percent,
                memory_bytes: process.memory_bytes,
            })
            .collect::<Vec<_>>();
        process_rows.sort_by(compare_process_rows);

        let cpu_percent = process_rows
            .iter()
            .map(|process| process.cpu_percent)
            .sum::<f64>();
        let memory_bytes = process_rows
            .iter()
            .map(|process| process.memory_bytes)
            .sum::<u64>();
        let hottest_process = process_rows.first().cloned();
        let peak_cpu_percent = Some(
            cpu_percent.max(
                previous_row
                    .and_then(|row| row.peak_cpu_percent)
                    .unwrap_or(0.0),
            ),
        );
        let peak_memory_bytes = Some(
            memory_bytes.max(
                previous_row
                    .and_then(|row| row.peak_memory_bytes)
                    .unwrap_or(0),
            ),
        );

        TaskManagerPaneRow {
            window_id: pane.window_id.clone(),
            window_title: pane.window_title.clone(),
            worklane_id: pane.worklane_id.clone(),
            worklane_title: pane.worklane_title.clone(),
            pane_id: pane.pane_id.clone(),
            pane_title: pane.pane_title.clone(),
            status_text: pane.status_text.clone(),
            current_working_directory: pane.current_working_directory.clone(),
            root_pid: pane.root_pid,
            availability: TaskManagerAvailability::Available,
            cpu_percent: Some(cpu_percent),
            peak_cpu_percent,
            memory_bytes: Some(memory_bytes),
            peak_memory_bytes,
            network_state: process_tree
                .network_bytes_per_second
                .map(|bytes_per_second| TaskManagerNetworkState::Available { bytes_per_second })
                .unwrap_or_else(|| TaskManagerNetworkState::Unavailable("Unavailable".to_string())),
            hottest_process,
            process_rows,
            is_remote: pane.is_remote,
        }
    }

    fn unavailable_row(
        pane: &TaskManagerPaneSource,
        reason: &str,
        previous_row: Option<&TaskManagerPaneRow>,
    ) -> TaskManagerPaneRow {
        TaskManagerPaneRow {
            window_id: pane.window_id.clone(),
            window_title: pane.window_title.clone(),
            worklane_id: pane.worklane_id.clone(),
            worklane_title: pane.worklane_title.clone(),
            pane_id: pane.pane_id.clone(),
            pane_title: pane.pane_title.clone(),
            status_text: pane.status_text.clone(),
            current_working_directory: pane.current_working_directory.clone(),
            root_pid: pane.root_pid,
            availability: TaskManagerAvailability::Unavailable(reason.to_string()),
            cpu_percent: None,
            peak_cpu_percent: previous_row.and_then(|row| row.peak_cpu_percent),
            memory_bytes: None,
            peak_memory_bytes: previous_row.and_then(|row| row.peak_memory_bytes),
            network_state: TaskManagerNetworkState::Unavailable("Unavailable".to_string()),
            hottest_process: None,
            process_rows: Vec::new(),
            is_remote: pane.is_remote,
        }
    }
}

pub struct TaskManagerRowFilter;

impl TaskManagerRowFilter {
    pub fn filter<'a>(rows: &'a [TaskManagerPaneRow], query: &str) -> Vec<&'a TaskManagerPaneRow> {
        let needle = query.trim().to_lowercase();
        if needle.is_empty() {
            return rows.iter().collect();
        }

        rows.iter()
            .filter(|row| searchable_text(row).contains(&needle))
            .collect()
    }
}

pub struct TaskManagerStableSorter;

impl TaskManagerStableSorter {
    const CPU_HYSTERESIS_PERCENT: f64 = 1.0;

    pub fn sort(rows: &[TaskManagerPaneRow], previous_order: &[String]) -> Vec<TaskManagerPaneRow> {
        let previous_index = previous_order
            .iter()
            .enumerate()
            .map(|(index, pane_id)| (pane_id.as_str(), index))
            .collect::<BTreeMap<_, _>>();
        let mut sorted = rows.to_vec();
        sorted.sort_by(|lhs, rhs| {
            let lhs_cpu = lhs.cpu_percent.unwrap_or(-1.0);
            let rhs_cpu = rhs.cpu_percent.unwrap_or(-1.0);
            if (lhs_cpu - rhs_cpu).abs() <= Self::CPU_HYSTERESIS_PERCENT
                && let (Some(lhs_previous), Some(rhs_previous)) = (
                    previous_index.get(lhs.pane_id.as_str()),
                    previous_index.get(rhs.pane_id.as_str()),
                )
                    && lhs_previous != rhs_previous {
                        return lhs_previous.cmp(rhs_previous);
                    }
            rhs_cpu
                .partial_cmp(&lhs_cpu)
                .unwrap_or(Ordering::Equal)
                .then_with(|| {
                    rhs.memory_bytes
                        .unwrap_or(0)
                        .cmp(&lhs.memory_bytes.unwrap_or(0))
                })
                .then_with(|| natural_compare(&lhs.pane_title, &rhs.pane_title))
        });
        sorted
    }
}

pub struct TaskManagerMetricFormatter;

impl TaskManagerMetricFormatter {
    pub fn cpu(value: Option<f64>) -> String {
        value
            .map(|value| format!("{value:.1}%"))
            .unwrap_or_else(|| "-".to_string())
    }

    pub fn memory(bytes: Option<u64>) -> String {
        bytes
            .map(format_byte_count)
            .unwrap_or_else(|| "-".to_string())
    }

    pub fn network(state: &TaskManagerNetworkState) -> String {
        match state {
            TaskManagerNetworkState::Available { bytes_per_second } => {
                format!("{}/s", format_byte_count(*bytes_per_second))
            }
            TaskManagerNetworkState::Unavailable(_) => "-".to_string(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskManagerProbeSample {
    pub cpu_time_nanoseconds: u64,
    pub parent_pid: Option<i32>,
    pub name: String,
    pub memory_bytes: u64,
}

pub trait TaskManagerProcessProbing {
    fn tree_pids(&self, root_pid: i32) -> Vec<i32>;
    fn sample(&self, pid: i32) -> Option<TaskManagerProbeSample>;
}

#[derive(Clone, Copy, Debug)]
struct Sample {
    cpu_time_nanoseconds: u64,
    sampled_at_seconds: f64,
}

pub struct TaskManagerProcessSampler<P> {
    probe: P,
    previous_samples_by_pid: BTreeMap<i32, Sample>,
}

impl<P> TaskManagerProcessSampler<P>
where
    P: TaskManagerProcessProbing,
{
    pub fn new(probe: P) -> Self {
        Self {
            probe,
            previous_samples_by_pid: BTreeMap::new(),
        }
    }

    pub fn sample_root_pids(
        &mut self,
        root_pids: &[i32],
        now_seconds: f64,
    ) -> BTreeMap<i32, TaskManagerProcessTree> {
        let mut trees = BTreeMap::new();
        let mut next_samples = BTreeMap::new();

        for root_pid in root_pids.iter().copied().filter(|root_pid| *root_pid > 0) {
            let pids = self.probe.tree_pids(root_pid);
            if pids.is_empty() {
                continue;
            }

            let processes = pids
                .into_iter()
                .filter_map(|pid| {
                    let reading = self.probe.sample(pid)?;
                    let previous = self.previous_samples_by_pid.get(&pid).copied();
                    next_samples.insert(
                        pid,
                        Sample {
                            cpu_time_nanoseconds: reading.cpu_time_nanoseconds,
                            sampled_at_seconds: now_seconds,
                        },
                    );
                    Some(TaskManagerProcessMetric {
                        pid,
                        parent_pid: reading.parent_pid,
                        name: reading.name,
                        cpu_percent: cpu_percent(
                            reading.cpu_time_nanoseconds,
                            previous,
                            now_seconds,
                        ),
                        memory_bytes: reading.memory_bytes,
                    })
                })
                .collect::<Vec<_>>();

            trees.insert(
                root_pid,
                TaskManagerProcessTree {
                    root_pid,
                    processes,
                    network_bytes_per_second: None,
                },
            );
        }

        self.previous_samples_by_pid = next_samples;
        trees
    }

    pub fn sample_root_pid(
        &mut self,
        root_pid: i32,
        now_seconds: f64,
    ) -> Option<TaskManagerProcessTree> {
        if root_pid <= 0 {
            return None;
        }
        self.sample_root_pids(&[root_pid], now_seconds)
            .remove(&root_pid)
    }
}

fn compare_process_rows(lhs: &TaskManagerProcessRow, rhs: &TaskManagerProcessRow) -> Ordering {
    rhs.cpu_percent
        .partial_cmp(&lhs.cpu_percent)
        .unwrap_or(Ordering::Equal)
        .then_with(|| rhs.memory_bytes.cmp(&lhs.memory_bytes))
        .then_with(|| lhs.pid.cmp(&rhs.pid))
}

fn searchable_text(row: &TaskManagerPaneRow) -> String {
    let mut values = vec![
        row.window_title.clone(),
        row.worklane_title.clone(),
        row.pane_title.clone(),
    ];
    values.extend(row.status_text.clone());
    values.extend(row.current_working_directory.clone());
    values.extend(row.root_pid.map(|pid| pid.to_string()));
    values.extend(
        row.hottest_process
            .as_ref()
            .map(|process| process.name.clone()),
    );
    values.extend(
        row.hottest_process
            .as_ref()
            .map(|process| process.pid.to_string()),
    );
    for process in &row.process_rows {
        values.push(process.name.clone());
        values.push(process.pid.to_string());
        values.extend(process.parent_pid.map(|pid| pid.to_string()));
    }
    values.join(" ").to_lowercase()
}

fn cpu_percent(current: u64, previous: Option<Sample>, now_seconds: f64) -> f64 {
    let Some(previous) = previous else {
        return 0.0;
    };
    let elapsed = now_seconds - previous.sampled_at_seconds;
    if elapsed <= 0.0 || current <= previous.cpu_time_nanoseconds {
        return 0.0;
    }
    let delta = current - previous.cpu_time_nanoseconds;
    delta as f64 / (elapsed * 1_000_000_000.0) * 100.0
}

fn format_byte_count(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["bytes", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit + 1 < UNITS.len() {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 {
        if bytes == 1 {
            "1 byte".to_string()
        } else {
            format!("{bytes} bytes")
        }
    } else if value >= 10.0 || (value.fract()).abs() < f64::EPSILON {
        format!("{value:.0} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn natural_compare(lhs: &str, rhs: &str) -> Ordering {
    let mut lhs_chars = lhs.chars().peekable();
    let mut rhs_chars = rhs.chars().peekable();

    loop {
        match (lhs_chars.peek(), rhs_chars.peek()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(lhs_ch), Some(rhs_ch)) if lhs_ch.is_ascii_digit() && rhs_ch.is_ascii_digit() => {
                let lhs_number = take_number(&mut lhs_chars);
                let rhs_number = take_number(&mut rhs_chars);
                match lhs_number.cmp(&rhs_number) {
                    Ordering::Equal => {}
                    ordering => return ordering,
                }
            }
            (Some(_), Some(_)) => {
                let lhs_ch = lhs_chars.next().expect("peeked char should exist");
                let rhs_ch = rhs_chars.next().expect("peeked char should exist");
                match lhs_ch
                    .to_ascii_lowercase()
                    .cmp(&rhs_ch.to_ascii_lowercase())
                {
                    Ordering::Equal => {}
                    ordering => return ordering,
                }
            }
        }
    }
}

fn take_number<I>(chars: &mut std::iter::Peekable<I>) -> u64
where
    I: Iterator<Item = char>,
{
    let mut value = 0_u64;
    while chars.peek().is_some_and(|ch| ch.is_ascii_digit()) {
        let digit = chars
            .next()
            .and_then(|ch| ch.to_digit(10))
            .expect("peeked digit should parse");
        value = value.saturating_mul(10).saturating_add(u64::from(digit));
    }
    value
}
