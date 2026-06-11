use std::error::Error;
use std::fmt;
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use zentty_core::agent::{AgentIpcRequest, AgentIpcResponse};

pub const AGENT_IPC_MAX_REQUEST_BYTES: usize = 256 * 1024;
const AGENT_IPC_RESPONSE_TIMEOUT: Duration = Duration::from_secs(2);
const AGENT_IPC_INSTANCE_ID_BYTES: usize = 16;
const AGENT_IPC_PANE_TOKEN_BYTES: usize = 32;

#[derive(Debug)]
pub enum AgentIpcTransportError {
    Io(io::Error),
    Json(serde_json::Error),
    InvalidMessage,
    RequestTooLarge,
    UnsupportedPlatform,
    Native(String),
}

impl fmt::Display for AgentIpcTransportError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "{error}"),
            Self::Json(error) => write!(formatter, "{error}"),
            Self::InvalidMessage => formatter.write_str("invalid IPC message"),
            Self::RequestTooLarge => formatter.write_str("IPC request is too large"),
            Self::UnsupportedPlatform => {
                formatter.write_str("agent IPC named pipes are only supported on Windows")
            }
            Self::Native(message) => formatter.write_str(message),
        }
    }
}

impl Error for AgentIpcTransportError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Json(error) => Some(error),
            Self::InvalidMessage
            | Self::RequestTooLarge
            | Self::UnsupportedPlatform
            | Self::Native(_) => None,
        }
    }
}

impl From<io::Error> for AgentIpcTransportError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for AgentIpcTransportError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

pub fn read_agent_ipc_request_data<R: Read>(
    reader: &mut R,
) -> Result<Vec<u8>, AgentIpcTransportError> {
    let mut data = Vec::new();
    let mut buffer = [0u8; 4096];

    loop {
        let received_count = reader.read(&mut buffer)?;
        if received_count == 0 {
            return if data.is_empty() {
                Err(AgentIpcTransportError::InvalidMessage)
            } else {
                Ok(data)
            };
        }

        let received = &buffer[..received_count];
        if let Some(newline_index) = received.iter().position(|byte| *byte == b'\n') {
            if data.len() + newline_index > AGENT_IPC_MAX_REQUEST_BYTES {
                return Err(AgentIpcTransportError::RequestTooLarge);
            }
            data.extend_from_slice(&received[..newline_index]);
            return Ok(data);
        }

        data.extend_from_slice(received);
        if data.len() > AGENT_IPC_MAX_REQUEST_BYTES {
            return Err(AgentIpcTransportError::RequestTooLarge);
        }
    }
}

pub fn read_agent_ipc_request<R: Read>(
    reader: &mut R,
) -> Result<AgentIpcRequest, AgentIpcTransportError> {
    let data = read_agent_ipc_request_data(reader)?;
    Ok(serde_json::from_slice(&data)?)
}

pub fn read_agent_ipc_response<R: Read>(
    reader: &mut R,
) -> Result<AgentIpcResponse, AgentIpcTransportError> {
    let data = read_agent_ipc_request_data(reader)?;
    Ok(serde_json::from_slice(&data)?)
}

pub fn write_agent_ipc_response<W: Write>(
    writer: &mut W,
    response: &AgentIpcResponse,
) -> Result<(), AgentIpcTransportError> {
    serde_json::to_writer(&mut *writer, response)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}

pub fn handle_agent_ipc_stream<S, F>(
    stream: &mut S,
    handler: F,
) -> Result<(), AgentIpcTransportError>
where
    S: Read + Write,
    F: FnOnce(AgentIpcRequest) -> Option<AgentIpcResponse>,
{
    let request = read_agent_ipc_request(stream)?;
    if let Some(response) = handler(request) {
        write_agent_ipc_response(stream, &response)?;
    }
    Ok(())
}

pub fn generate_agent_ipc_instance_id() -> Result<String, AgentIpcTransportError> {
    random_hex(AGENT_IPC_INSTANCE_ID_BYTES)
}

pub fn generate_agent_ipc_pane_token() -> Result<String, AgentIpcTransportError> {
    random_hex(AGENT_IPC_PANE_TOKEN_BYTES)
}

pub fn agent_ipc_pipe_path_for_instance(instance_id: &str) -> String {
    let sanitized = instance_id
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric() || *ch == '-' || *ch == '_')
        .collect::<String>();
    let instance_id = if sanitized.is_empty() {
        "default"
    } else {
        sanitized.as_str()
    };
    format!(r"\\.\pipe\zentty-agent-{instance_id}")
}

#[cfg(windows)]
pub fn send_agent_ipc_request(
    pipe_path: &str,
    request: &AgentIpcRequest,
) -> Result<Option<AgentIpcResponse>, AgentIpcTransportError> {
    use std::fs::{File, OpenOptions};
    use std::time::Instant;

    fn open_with_retry(path: &str, timeout: Duration) -> Result<File, io::Error> {
        let deadline = Instant::now() + timeout;
        loop {
            match OpenOptions::new().read(true).write(true).open(path) {
                Ok(file) => return Ok(file),
                Err(error) if Instant::now() < deadline => {
                    let _ = error;
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => return Err(error),
            }
        }
    }

    let mut pipe = open_with_retry(pipe_path, AGENT_IPC_RESPONSE_TIMEOUT)?;
    serde_json::to_writer(&mut pipe, request)?;
    pipe.write_all(b"\n")?;
    pipe.flush()?;
    if request.expects_response {
        read_agent_ipc_response(&mut pipe).map(Some)
    } else {
        Ok(None)
    }
}

#[cfg(not(windows))]
pub fn send_agent_ipc_request(
    _pipe_path: &str,
    _request: &AgentIpcRequest,
) -> Result<Option<AgentIpcResponse>, AgentIpcTransportError> {
    Err(AgentIpcTransportError::UnsupportedPlatform)
}

pub struct AgentIpcConnectionRequest {
    pub request: AgentIpcRequest,
    response_sender: mpsc::Sender<Option<AgentIpcResponse>>,
}

impl AgentIpcConnectionRequest {
    pub fn respond(self, response: Option<AgentIpcResponse>) {
        let _ = self.response_sender.send(response);
    }

    pub fn dispatch<F>(self, handler: F)
    where
        F: FnOnce(AgentIpcRequest) -> Option<AgentIpcResponse>,
    {
        let response = handler(self.request);
        let _ = self.response_sender.send(response);
    }
}

pub struct AgentIpcNamedPipeListener {
    pipe_path: String,
    request_receiver: mpsc::Receiver<AgentIpcConnectionRequest>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl AgentIpcNamedPipeListener {
    pub fn start(pipe_path: impl Into<String>) -> Result<Self, AgentIpcTransportError> {
        start_agent_ipc_named_pipe_listener(pipe_path.into())
    }

    pub fn try_recv(&self) -> Option<AgentIpcConnectionRequest> {
        self.request_receiver.try_recv().ok()
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Option<AgentIpcConnectionRequest> {
        self.request_receiver.recv_timeout(timeout).ok()
    }

    fn stop_and_join(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        unblock_agent_ipc_named_pipe(&self.pipe_path);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for AgentIpcNamedPipeListener {
    fn drop(&mut self) {
        self.stop_and_join();
    }
}

#[cfg(windows)]
pub fn serve_agent_ipc_named_pipe_once<F>(
    pipe_path: &str,
    handler: F,
) -> Result<(), AgentIpcTransportError>
where
    F: FnOnce(AgentIpcRequest) -> Option<AgentIpcResponse>,
{
    use std::fs::File;
    use std::os::windows::io::{AsRawHandle, FromRawHandle};

    use windows::Win32::Foundation::{
        ERROR_PIPE_CONNECTED, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
    use windows::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS,
        PIPE_TYPE_BYTE, PIPE_WAIT,
    };
    use windows::core::PCWSTR;

    let wide_path = wide_null(pipe_path);
    let handle = unsafe {
        CreateNamedPipeW(
            PCWSTR(wide_path.as_ptr()),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            64 * 1024,
            64 * 1024,
            2_000,
            None,
        )
    };
    if handle == INVALID_HANDLE_VALUE || handle.is_invalid() {
        return Err(windows::core::Error::from_thread().into());
    }

    let mut pipe = unsafe { File::from_raw_handle(handle.0) };
    if let Err(error) = unsafe { ConnectNamedPipe(HANDLE(pipe.as_raw_handle()), None) } {
        let last_error = unsafe { GetLastError() };
        if last_error != ERROR_PIPE_CONNECTED {
            return Err(error.into());
        }
    }

    
    handle_agent_ipc_stream(&mut pipe, handler)
}

#[cfg(not(windows))]
pub fn serve_agent_ipc_named_pipe_once<F>(
    _pipe_path: &str,
    _handler: F,
) -> Result<(), AgentIpcTransportError>
where
    F: FnOnce(AgentIpcRequest) -> Option<AgentIpcResponse>,
{
    Err(AgentIpcTransportError::UnsupportedPlatform)
}

#[cfg(windows)]
fn start_agent_ipc_named_pipe_listener(
    pipe_path: String,
) -> Result<AgentIpcNamedPipeListener, AgentIpcTransportError> {
    let (request_sender, request_receiver) = mpsc::channel();
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let thread_pipe_path = pipe_path.clone();
    let thread = thread::Builder::new()
        .name("zentty-agent-ipc".to_string())
        .spawn(move || {
            while !thread_stop.load(Ordering::SeqCst) {
                let sender = request_sender.clone();
                let result = serve_agent_ipc_named_pipe_once(&thread_pipe_path, move |request| {
                    let (response_sender, response_receiver) = mpsc::channel();
                    if sender
                        .send(AgentIpcConnectionRequest {
                            request,
                            response_sender,
                        })
                        .is_err()
                    {
                        return None;
                    }
                    response_receiver
                        .recv_timeout(AGENT_IPC_RESPONSE_TIMEOUT)
                        .ok()
                        .flatten()
                });

                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                if result.is_err() {
                    thread::sleep(Duration::from_millis(10));
                }
            }
        })?;

    Ok(AgentIpcNamedPipeListener {
        pipe_path,
        request_receiver,
        stop,
        thread: Some(thread),
    })
}

#[cfg(not(windows))]
fn start_agent_ipc_named_pipe_listener(
    pipe_path: String,
) -> Result<AgentIpcNamedPipeListener, AgentIpcTransportError> {
    let (_request_sender, request_receiver) = mpsc::channel();
    Ok(AgentIpcNamedPipeListener {
        pipe_path,
        request_receiver,
        stop: Arc::new(AtomicBool::new(true)),
        thread: None,
    })
    .and(Err(AgentIpcTransportError::UnsupportedPlatform))
}

#[cfg(windows)]
fn unblock_agent_ipc_named_pipe(pipe_path: &str) {
    use std::fs::OpenOptions;

    let _ = OpenOptions::new().read(true).write(true).open(pipe_path);
}

#[cfg(not(windows))]
fn unblock_agent_ipc_named_pipe(_pipe_path: &str) {}

fn random_hex(byte_count: usize) -> Result<String, AgentIpcTransportError> {
    let mut bytes = vec![0u8; byte_count];
    fill_secure_random(&mut bytes)?;
    let mut value = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        value.push_str(&format!("{byte:02x}"));
    }
    Ok(value)
}

#[cfg(windows)]
fn fill_secure_random(buffer: &mut [u8]) -> Result<(), AgentIpcTransportError> {
    use windows::Win32::Security::Cryptography::{
        BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom,
    };

    let status = unsafe { BCryptGenRandom(None, buffer, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    if status.0 < 0 {
        return Err(AgentIpcTransportError::Native(format!(
            "BCryptGenRandom failed with NTSTATUS 0x{:08x}",
            status.0 as u32
        )));
    }
    Ok(())
}

#[cfg(not(windows))]
fn fill_secure_random(_buffer: &mut [u8]) -> Result<(), AgentIpcTransportError> {
    Err(AgentIpcTransportError::UnsupportedPlatform)
}

#[cfg(windows)]
impl From<windows::core::Error> for AgentIpcTransportError {
    fn from(error: windows::core::Error) -> Self {
        Self::Native(error.to_string())
    }
}

#[cfg(windows)]
fn wide_null(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
