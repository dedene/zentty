use std::io::{Read, Write};
use std::sync::mpsc::{self, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};

use crate::{PtyError, PtyProcessOutput, PtySessionRequest, TerminalSize};

pub struct NativePtySession {
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    reader: Option<Box<dyn Read + Send>>,
    writer: Option<Box<dyn Write + Send>>,
}

impl NativePtySession {
    pub fn spawn(request: PtySessionRequest, size: TerminalSize) -> Result<Self, PtyError> {
        request.validate()?;

        let pty_system = native_pty_system();
        let pair = pty_system.openpty(size.into())?;
        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let child = pair.slave.spawn_command(command_builder(&request))?;

        Ok(Self {
            master: pair.master,
            child,
            reader: Some(reader),
            writer: Some(writer),
        })
    }

    pub fn resize(&self, size: TerminalSize) -> Result<(), PtyError> {
        self.master.resize(size.into())?;
        Ok(())
    }

    pub fn write_all(&mut self, bytes: &[u8]) -> Result<(), PtyError> {
        if let Some(writer) = self.writer.as_mut() {
            writer.write_all(bytes)?;
            writer.flush()?;
        }
        Ok(())
    }

    pub fn terminate(&mut self) -> Result<(), PtyError> {
        drop(self.writer.take());
        if self.child.try_wait()?.is_none() {
            self.child.kill()?;
        }
        Ok(())
    }

    pub fn wait_with_output(mut self, timeout: Duration) -> Result<PtyProcessOutput, PtyError> {
        let mut reader = self
            .reader
            .take()
            .ok_or(PtyError::OutputReaderAlreadyTaken)?;
        let (sender, receiver) = mpsc::channel::<std::io::Result<Vec<u8>>>();

        thread::spawn(move || {
            let mut buffer = [0_u8; 4096];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        if sender.send(Ok(buffer[..count].to_vec())).is_err() {
                            break;
                        }
                    }
                    Err(error) => {
                        let _ = sender.send(Err(error));
                        break;
                    }
                }
            }
        });

        let deadline = Instant::now() + timeout;
        let mut output = Vec::new();
        let mut answered_cursor_position_query = false;
        let status = loop {
            drain_available_output(&receiver, &mut output)?;
            if !answered_cursor_position_query && contains_cursor_position_query(&output) {
                if let Some(writer) = self.writer.as_mut() {
                    writer.write_all(b"\x1b[1;1R")?;
                    writer.flush()?;
                }
                answered_cursor_position_query = true;
            }

            if let Some(status) = self.child.try_wait()? {
                break status;
            }

            if Instant::now() >= deadline {
                let _ = self.child.kill();
                drop(self.writer.take());
                drop(self.master);
                drain_available_output(&receiver, &mut output)?;
                return Err(PtyError::OutputTimeout {
                    timeout,
                    output: String::from_utf8_lossy(&output).into_owned(),
                });
            }

            thread::sleep(Duration::from_millis(10));
        };

        drop(self.writer.take());
        drop(self.master);

        let output_timeout = Duration::from_secs(2);
        let output_deadline = Instant::now() + output_timeout;
        loop {
            drain_available_output(&receiver, &mut output)?;
            if Instant::now() >= output_deadline {
                return Err(PtyError::OutputTimeout {
                    timeout: output_timeout,
                    output: String::from_utf8_lossy(&output).into_owned(),
                });
            }

            match receiver.recv_timeout(Duration::from_millis(10)) {
                Ok(Ok(chunk)) => output.extend_from_slice(&chunk),
                Ok(Err(error)) => return Err(PtyError::Io(error)),
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }

        Ok(PtyProcessOutput {
            status_success: status.success(),
            exit_code: Some(status.exit_code()),
            output: String::from_utf8_lossy(&output).into_owned(),
        })
    }

    pub fn run_with_streams<R, W>(
        self,
        mut input: R,
        mut output: W,
        timeout: Option<Duration>,
    ) -> Result<PtyProcessOutput, PtyError>
    where
        R: Read + Send + 'static,
        W: Write + Send + 'static,
    {
        let NativePtySession {
            master,
            mut child,
            reader,
            writer,
        } = self;
        let mut reader = reader.ok_or(PtyError::OutputReaderAlreadyTaken)?;
        let writer = writer.ok_or(PtyError::InputWriterAlreadyTaken)?;
        let writer = Arc::new(Mutex::new(Some(writer)));

        let input_writer = Arc::clone(&writer);
        thread::spawn(move || {
            let mut buffer = [0_u8; 4096];
            loop {
                let count = match input.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => count,
                    Err(_) => break,
                };

                let Ok(mut writer) = input_writer.lock() else {
                    break;
                };
                let Some(writer) = writer.as_mut() else {
                    break;
                };
                if writer.write_all(&buffer[..count]).is_err() || writer.flush().is_err() {
                    break;
                }
            }
        });

        let output_writer = Arc::clone(&writer);
        let output_thread = thread::spawn(move || -> std::io::Result<Vec<u8>> {
            let mut buffer = [0_u8; 4096];
            let mut captured = Vec::new();
            let mut answered_cursor_position_query = false;

            loop {
                let count = reader.read(&mut buffer)?;
                if count == 0 {
                    break;
                }

                let chunk = &buffer[..count];
                captured.extend_from_slice(chunk);
                output.write_all(chunk)?;
                output.flush()?;

                if !answered_cursor_position_query && contains_cursor_position_query(&captured) {
                    if let Ok(mut writer) = output_writer.lock()
                        && let Some(writer) = writer.as_mut()
                    {
                        writer.write_all(b"\x1b[1;1R")?;
                        writer.flush()?;
                    }
                    answered_cursor_position_query = true;
                }
            }

            Ok(captured)
        });

        let deadline = timeout.map(|timeout| Instant::now() + timeout);
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status;
            }

            if let Some(deadline) = deadline
                && Instant::now() >= deadline
            {
                let _ = child.kill();
                close_shared_writer(&writer)?;
                drop(master);
                let output = join_output_thread(output_thread)?;
                return Err(PtyError::OutputTimeout {
                    timeout: timeout.expect("deadline exists only when timeout exists"),
                    output: String::from_utf8_lossy(&output).into_owned(),
                });
            }

            thread::sleep(Duration::from_millis(10));
        };

        close_shared_writer(&writer)?;
        drop(master);
        let output = join_output_thread(output_thread)?;

        Ok(PtyProcessOutput {
            status_success: status.success(),
            exit_code: Some(status.exit_code()),
            output: String::from_utf8_lossy(&output).into_owned(),
        })
    }

    pub fn into_output_stream(self) -> Result<NativePtyOutputStream, PtyError> {
        let NativePtySession {
            master,
            child,
            reader,
            writer,
        } = self;
        let mut reader = reader.ok_or(PtyError::OutputReaderAlreadyTaken)?;
        let writer = writer.ok_or(PtyError::InputWriterAlreadyTaken)?;
        let (sender, receiver) = mpsc::channel::<std::io::Result<Vec<u8>>>();
        let reader_thread = thread::spawn(move || {
            let mut buffer = [0_u8; 4096];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        if sender.send(Ok(buffer[..count].to_vec())).is_err() {
                            break;
                        }
                    }
                    Err(error) => {
                        let _ = sender.send(Err(error));
                        break;
                    }
                }
            }
        });

        Ok(NativePtyOutputStream {
            master: Some(master),
            child,
            writer: Some(writer),
            receiver,
            reader_thread: Some(reader_thread),
            output: Vec::new(),
            answered_cursor_position_query: false,
        })
    }
}

pub struct NativePtyOutputStream {
    master: Option<Box<dyn MasterPty + Send>>,
    child: Box<dyn Child + Send + Sync>,
    writer: Option<Box<dyn Write + Send>>,
    receiver: mpsc::Receiver<std::io::Result<Vec<u8>>>,
    reader_thread: Option<thread::JoinHandle<()>>,
    output: Vec<u8>,
    answered_cursor_position_query: bool,
}

impl NativePtyOutputStream {
    pub fn write_all(&mut self, bytes: &[u8]) -> Result<(), PtyError> {
        if let Some(writer) = self.writer.as_mut() {
            writer.write_all(bytes)?;
            writer.flush()?;
        }
        Ok(())
    }

    pub fn resize(&self, size: TerminalSize) -> Result<(), PtyError> {
        if let Some(master) = self.master.as_ref() {
            master.resize(size.into())?;
        }
        Ok(())
    }

    pub fn read_available(&mut self) -> Result<String, PtyError> {
        self.drain_output()?;
        Ok(String::from_utf8_lossy(&self.output).into_owned())
    }

    /// Whether the underlying shell process has exited. Used by the desktop
    /// poll loop to auto-close a pane whose shell ended (standard terminal
    /// behavior). `try_wait` is non-blocking; on its own failure we report
    /// "not exited" so a transient query error never closes a live pane.
    pub fn has_exited(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(Some(_)))
    }

    pub fn read_available_bytes(&mut self) -> Result<Vec<u8>, PtyError> {
        let previous_len = self.output.len();
        self.drain_output()?;
        Ok(self.output[previous_len..].to_vec())
    }

    pub fn read_until_contains(
        &mut self,
        needle: &str,
        timeout: Duration,
    ) -> Result<String, PtyError> {
        let deadline = Instant::now() + timeout;
        loop {
            self.drain_output()?;
            let output = String::from_utf8_lossy(&self.output);
            if output.contains(needle) {
                return Ok(output.into_owned());
            }
            if Instant::now() >= deadline {
                return Err(PtyError::OutputTimeout {
                    timeout,
                    output: output.into_owned(),
                });
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    pub fn wait_with_output(mut self, timeout: Duration) -> Result<PtyProcessOutput, PtyError> {
        let deadline = Instant::now() + timeout;
        let status = loop {
            self.drain_output()?;
            if let Some(status) = self.child.try_wait()? {
                break status;
            }
            if Instant::now() >= deadline {
                let _ = self.child.kill();
                self.close_writer();
                self.close_master();
                self.join_reader_thread()?;
                self.drain_output()?;
                return Err(PtyError::OutputTimeout {
                    timeout,
                    output: String::from_utf8_lossy(&self.output).into_owned(),
                });
            }
            thread::sleep(Duration::from_millis(10));
        };

        self.close_writer();
        self.close_master();
        self.join_reader_thread()?;
        self.drain_output()?;

        Ok(PtyProcessOutput {
            status_success: status.success(),
            exit_code: Some(status.exit_code()),
            output: String::from_utf8_lossy(&self.output).into_owned(),
        })
    }

    fn drain_output(&mut self) -> Result<(), PtyError> {
        drain_available_output(&self.receiver, &mut self.output)?;
        if !self.answered_cursor_position_query && contains_cursor_position_query(&self.output) {
            if let Some(writer) = self.writer.as_mut() {
                writer.write_all(b"\x1b[1;1R")?;
                writer.flush()?;
            }
            self.answered_cursor_position_query = true;
        }
        Ok(())
    }

    fn close_writer(&mut self) {
        drop(self.writer.take());
    }

    fn close_master(&mut self) {
        drop(self.master.take());
    }

    fn join_reader_thread(&mut self) -> Result<(), PtyError> {
        if let Some(thread) = self.reader_thread.take() {
            thread
                .join()
                .map_err(|_| PtyError::Backend("PTY output thread panicked".to_string()))?;
        }
        Ok(())
    }

    pub fn terminate(&mut self) -> Result<(), PtyError> {
        self.close_writer();
        if self.child.try_wait()?.is_none() {
            self.child.kill()?;
        }
        self.close_master();
        self.join_reader_thread()?;
        Ok(())
    }
}

impl Drop for NativePtyOutputStream {
    fn drop(&mut self) {
        let _ = self.terminate();
    }
}

impl From<TerminalSize> for PtySize {
    fn from(size: TerminalSize) -> Self {
        PtySize {
            rows: size.rows,
            cols: size.cols,
            pixel_width: size.pixel_width,
            pixel_height: size.pixel_height,
        }
    }
}

fn command_builder(request: &PtySessionRequest) -> CommandBuilder {
    let mut command = CommandBuilder::new(request.program());
    command.args(request.args().iter().map(String::as_str));
    if let Some(cwd) = request.working_directory() {
        command.cwd(cwd.as_str());
    }
    for (key, value) in request.environment() {
        command.env(key.as_str(), value.as_str());
    }
    command
}

fn drain_available_output(
    receiver: &mpsc::Receiver<std::io::Result<Vec<u8>>>,
    output: &mut Vec<u8>,
) -> Result<(), PtyError> {
    loop {
        match receiver.try_recv() {
            Ok(Ok(chunk)) => output.extend_from_slice(&chunk),
            Ok(Err(error)) => return Err(PtyError::Io(error)),
            Err(TryRecvError::Empty) => return Ok(()),
            Err(TryRecvError::Disconnected) => return Ok(()),
        }
    }
}

fn contains_cursor_position_query(output: &[u8]) -> bool {
    output
        .windows(b"\x1b[6n".len())
        .any(|window| window == b"\x1b[6n")
}

fn close_shared_writer(writer: &Arc<Mutex<Option<Box<dyn Write + Send>>>>) -> Result<(), PtyError> {
    let mut writer = writer
        .lock()
        .map_err(|_| PtyError::Backend("PTY writer mutex poisoned".to_string()))?;
    drop(writer.take());
    Ok(())
}

fn join_output_thread(
    handle: thread::JoinHandle<std::io::Result<Vec<u8>>>,
) -> Result<Vec<u8>, PtyError> {
    handle
        .join()
        .map_err(|_| PtyError::Backend("PTY output thread panicked".to_string()))?
        .map_err(PtyError::Io)
}
