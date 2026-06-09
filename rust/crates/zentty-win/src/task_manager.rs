use std::collections::{BTreeMap, BTreeSet};

use zentty_core::task_manager::{
    TaskManagerAvailability, TaskManagerMetricFormatter, TaskManagerPaneRow,
    TaskManagerPaneRowBuilder, TaskManagerPaneSource, TaskManagerProbeSample,
    TaskManagerProcessProbing, TaskManagerProcessRow, TaskManagerProcessSampler,
    TaskManagerStableSorter,
};

#[derive(Clone, Debug, PartialEq)]
pub struct DesktopTaskManagerSnapshot {
    pub rows: Vec<TaskManagerPaneRow>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopTaskManagerTextSnapshot {
    pub lines: Vec<String>,
}

pub struct DesktopTaskManagerState<P> {
    sampler: TaskManagerProcessSampler<P>,
    previous_rows_by_key: BTreeMap<String, TaskManagerPaneRow>,
    previous_order: Vec<String>,
}

impl<P> DesktopTaskManagerState<P>
where
    P: TaskManagerProcessProbing,
{
    pub fn new(probe: P) -> Self {
        Self {
            sampler: TaskManagerProcessSampler::new(probe),
            previous_rows_by_key: BTreeMap::new(),
            previous_order: Vec::new(),
        }
    }

    pub fn snapshot(
        &mut self,
        sources: &[TaskManagerPaneSource],
        now_seconds: f64,
    ) -> DesktopTaskManagerSnapshot {
        let root_pids = sources
            .iter()
            .filter_map(|source| source.root_pid)
            .filter(|pid| *pid > 0)
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        let process_trees = self.sampler.sample_root_pids(&root_pids, now_seconds);
        let rows = sources
            .iter()
            .map(|source| {
                let row_key = pane_row_key(source);
                let previous = self.previous_rows_by_key.get(&row_key);
                let process_tree = source
                    .root_pid
                    .and_then(|root_pid| process_trees.get(&root_pid));
                TaskManagerPaneRowBuilder::row(source, process_tree, previous)
            })
            .collect::<Vec<_>>();
        let rows = TaskManagerStableSorter::sort(&rows, &self.previous_order);
        self.previous_order = rows.iter().map(|row| row.pane_id.clone()).collect();
        self.previous_rows_by_key = rows
            .iter()
            .map(|row| (pane_row_key_for_row(row), row.clone()))
            .collect();
        DesktopTaskManagerSnapshot { rows }
    }
}

impl DesktopTaskManagerTextSnapshot {
    pub fn from_snapshot(snapshot: &DesktopTaskManagerSnapshot) -> Self {
        let mut lines = vec![
            "Task Manager".to_string(),
            "Pane | CPU | Memory | Peak CPU | Peak Memory | Network | PID | Status | Hottest"
                .to_string(),
        ];

        if snapshot.rows.is_empty() {
            lines.push("No panes".to_string());
            return Self { lines };
        }

        for row in &snapshot.rows {
            lines.push(render_pane_row(row));
            for process in &row.process_rows {
                lines.push(render_process_row(process));
            }
        }

        Self { lines }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct WindowsTaskManagerProcessProbe;

impl WindowsTaskManagerProcessProbe {
    pub fn new() -> Self {
        Self
    }
}

impl TaskManagerProcessProbing for WindowsTaskManagerProcessProbe {
    fn tree_pids(&self, root_pid: i32) -> Vec<i32> {
        platform_tree_pids(root_pid)
    }

    fn sample(&self, pid: i32) -> Option<TaskManagerProbeSample> {
        platform_sample(pid)
    }
}

fn render_pane_row(row: &TaskManagerPaneRow) -> String {
    let pane_title = format!(
        "{} / {} / {}",
        row.window_title, row.worklane_title, row.pane_title
    );
    let status = match &row.availability {
        TaskManagerAvailability::Available => row
            .status_text
            .clone()
            .unwrap_or_else(|| "Available".to_string()),
        TaskManagerAvailability::Unavailable(reason) => reason.clone(),
    };
    let hottest = row
        .hottest_process
        .as_ref()
        .map(|process| format!("{} ({})", process.name, process.pid))
        .unwrap_or_else(|| "-".to_string());
    let pid = row
        .root_pid
        .map(|pid| pid.to_string())
        .unwrap_or_else(|| "-".to_string());

    format!(
        "{} | {} | {} | {} | {} | {} | {} | {} | {}",
        pane_title,
        TaskManagerMetricFormatter::cpu(row.cpu_percent),
        TaskManagerMetricFormatter::memory(row.memory_bytes),
        TaskManagerMetricFormatter::cpu(row.peak_cpu_percent),
        TaskManagerMetricFormatter::memory(row.peak_memory_bytes),
        TaskManagerMetricFormatter::network(&row.network_state),
        pid,
        status,
        hottest
    )
}

fn render_process_row(process: &TaskManagerProcessRow) -> String {
    let parent_pid = process
        .parent_pid
        .map(|pid| pid.to_string())
        .unwrap_or_else(|| "-".to_string());
    format!(
        "  {} ({}) parent {} cpu {} memory {}",
        process.name,
        process.pid,
        parent_pid,
        TaskManagerMetricFormatter::cpu(Some(process.cpu_percent)),
        TaskManagerMetricFormatter::memory(Some(process.memory_bytes))
    )
}

fn pane_row_key(source: &TaskManagerPaneSource) -> String {
    format!(
        "{}\u{1f}{}\u{1f}{}",
        source.window_id, source.worklane_id, source.pane_id
    )
}

fn pane_row_key_for_row(row: &TaskManagerPaneRow) -> String {
    format!(
        "{}\u{1f}{}\u{1f}{}",
        row.window_id, row.worklane_id, row.pane_id
    )
}

#[cfg(windows)]
fn platform_tree_pids(root_pid: i32) -> Vec<i32> {
    windows_probe::tree_pids(root_pid)
}

#[cfg(not(windows))]
fn platform_tree_pids(root_pid: i32) -> Vec<i32> {
    if root_pid > 0 {
        vec![root_pid]
    } else {
        Vec::new()
    }
}

#[cfg(windows)]
fn platform_sample(pid: i32) -> Option<TaskManagerProbeSample> {
    windows_probe::sample(pid)
}

#[cfg(not(windows))]
fn platform_sample(_pid: i32) -> Option<TaskManagerProbeSample> {
    None
}

#[cfg(windows)]
mod windows_probe {
    use std::collections::{BTreeMap, HashSet, VecDeque};
    use std::mem;

    use windows::Win32::Foundation::{CloseHandle, FILETIME, HANDLE};
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW,
        TH32CS_SNAPPROCESS,
    };
    use windows::Win32::System::ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS};
    use windows::Win32::System::Threading::{
        GetProcessTimes, OpenProcess, PROCESS_ACCESS_RIGHTS, PROCESS_QUERY_LIMITED_INFORMATION,
        PROCESS_VM_READ,
    };

    use zentty_core::task_manager::TaskManagerProbeSample;

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct ProcessEntry {
        pid: i32,
        parent_pid: Option<i32>,
        name: String,
    }

    pub(super) fn tree_pids(root_pid: i32) -> Vec<i32> {
        if root_pid <= 0 {
            return Vec::new();
        }

        let entries = process_entries();
        if !entries.iter().any(|entry| entry.pid == root_pid) {
            return Vec::new();
        }

        let mut children_by_parent = BTreeMap::<i32, Vec<i32>>::new();
        for entry in entries {
            if let Some(parent_pid) = entry.parent_pid {
                children_by_parent
                    .entry(parent_pid)
                    .or_default()
                    .push(entry.pid);
            }
        }
        for children in children_by_parent.values_mut() {
            children.sort_unstable();
        }

        let mut result = Vec::new();
        let mut seen = HashSet::new();
        let mut queue = VecDeque::from([root_pid]);
        while let Some(pid) = queue.pop_front() {
            if !seen.insert(pid) {
                continue;
            }
            result.push(pid);
            if let Some(children) = children_by_parent.get(&pid) {
                queue.extend(children.iter().copied());
            }
        }
        result
    }

    pub(super) fn sample(pid: i32) -> Option<TaskManagerProbeSample> {
        if pid <= 0 {
            return None;
        }
        let process_entry = process_entry(pid)?;
        let handle = open_process(pid)?;
        let cpu_time_nanoseconds = process_cpu_time_nanoseconds(handle.raw())?;
        let memory_bytes = process_memory_bytes(handle.raw()).unwrap_or(0);
        Some(TaskManagerProbeSample {
            cpu_time_nanoseconds,
            parent_pid: process_entry.parent_pid,
            name: process_entry.name,
            memory_bytes,
        })
    }

    fn process_entries() -> Vec<ProcessEntry> {
        let Ok(snapshot) = (unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }) else {
            return Vec::new();
        };
        let snapshot = OwnedHandle(snapshot);
        let mut entry = PROCESSENTRY32W {
            dwSize: mem::size_of::<PROCESSENTRY32W>() as u32,
            ..PROCESSENTRY32W::default()
        };

        if unsafe { Process32FirstW(snapshot.raw(), &mut entry) }.is_err() {
            return Vec::new();
        }

        let mut entries = Vec::new();
        loop {
            if let Some(process_entry) = process_entry_from_toolhelp(entry) {
                entries.push(process_entry);
            }
            if unsafe { Process32NextW(snapshot.raw(), &mut entry) }.is_err() {
                break;
            }
        }
        entries
    }

    fn process_entry(pid: i32) -> Option<ProcessEntry> {
        process_entries().into_iter().find(|entry| entry.pid == pid)
    }

    fn process_entry_from_toolhelp(entry: PROCESSENTRY32W) -> Option<ProcessEntry> {
        let pid = i32::try_from(entry.th32ProcessID).ok()?;
        if pid <= 0 {
            return None;
        }
        let parent_pid = i32::try_from(entry.th32ParentProcessID)
            .ok()
            .filter(|pid| *pid > 0);
        Some(ProcessEntry {
            pid,
            parent_pid,
            name: utf16_z_to_string(&entry.szExeFile),
        })
    }

    fn open_process(pid: i32) -> Option<OwnedHandle> {
        let pid = u32::try_from(pid).ok()?;
        let desired_access: PROCESS_ACCESS_RIGHTS =
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ;
        let handle = unsafe { OpenProcess(desired_access, false, pid) }
            .or_else(|_| unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) })
            .ok()?;
        Some(OwnedHandle(handle))
    }

    fn process_cpu_time_nanoseconds(handle: HANDLE) -> Option<u64> {
        let mut creation_time = FILETIME::default();
        let mut exit_time = FILETIME::default();
        let mut kernel_time = FILETIME::default();
        let mut user_time = FILETIME::default();
        unsafe {
            GetProcessTimes(
                handle,
                &mut creation_time,
                &mut exit_time,
                &mut kernel_time,
                &mut user_time,
            )
        }
        .ok()?;
        let kernel = filetime_100ns(kernel_time);
        let user = filetime_100ns(user_time);
        kernel.saturating_add(user).checked_mul(100)
    }

    fn process_memory_bytes(handle: HANDLE) -> Option<u64> {
        let mut counters = PROCESS_MEMORY_COUNTERS {
            cb: mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32,
            ..PROCESS_MEMORY_COUNTERS::default()
        };
        unsafe { GetProcessMemoryInfo(handle, &mut counters, counters.cb) }.ok()?;
        u64::try_from(counters.WorkingSetSize).ok()
    }

    fn filetime_100ns(filetime: FILETIME) -> u64 {
        (u64::from(filetime.dwHighDateTime) << 32) | u64::from(filetime.dwLowDateTime)
    }

    fn utf16_z_to_string(value: &[u16]) -> String {
        let len = value
            .iter()
            .position(|code_unit| *code_unit == 0)
            .unwrap_or(value.len());
        String::from_utf16_lossy(&value[..len])
    }

    struct OwnedHandle(HANDLE);

    impl OwnedHandle {
        fn raw(&self) -> HANDLE {
            self.0
        }
    }

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            let _ = unsafe { CloseHandle(self.0) };
        }
    }
}
