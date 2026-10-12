from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional
import socket
import time

import paramiko


@dataclass
class SSHConfig:
    host: str
    port: int = 22
    username: str = "root"
    password: str = ""
    key_path: str = ""
    key_passphrase: str = ""
    sudo_password: str = ""


class SSHError(RuntimeError):
    pass


class SSHSession:
    def __init__(self, config: SSHConfig):
        self.config = config
        self.client: Optional[paramiko.SSHClient] = None

    def connect(self, timeout: float = 10.0) -> None:
        self.close()
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        kwargs = dict(
            hostname=self.config.host,
            port=self.config.port,
            username=self.config.username,
            timeout=timeout,
            banner_timeout=timeout,
            auth_timeout=timeout,
            allow_agent=True,
            look_for_keys=True,
        )
        if self.config.password:
            kwargs["password"] = self.config.password
        if self.config.key_path:
            kwargs["key_filename"] = str(Path(self.config.key_path).expanduser())
        if self.config.key_passphrase:
            kwargs["passphrase"] = self.config.key_passphrase
        try:
            client.connect(**kwargs)
        except (paramiko.SSHException, socket.error, OSError) as exc:
            raise SSHError(f"SSH connection to {self.config.host}:{self.config.port} failed: {exc}") from exc
        self.client = client

    def close(self) -> None:
        if self.client is not None:
            self.client.close()
        self.client = None

    def _require(self) -> paramiko.SSHClient:
        if self.client is None:
            raise SSHError("SSH session is not connected")
        return self.client

    def _exec_stream(self, command: str, timeout: float, input_data: bytes = b"",
                     on_line: Optional[Callable[[str], None]] = None) -> tuple[int, str, str]:
        transport = self._require().get_transport()
        if transport is None or not transport.is_active():
            raise SSHError("SSH transport is not active")
        channel = transport.open_session(timeout=timeout)
        channel.exec_command(command)
        if input_data:
            channel.sendall(input_data)
        channel.shutdown_write()
        out = bytearray(); err = bytearray(); out_pending = ""; err_pending = ""
        deadline = time.monotonic() + timeout
        while True:
            progressed = False
            if channel.recv_ready():
                chunk = channel.recv(65536); out.extend(chunk); progressed = True
                if on_line:
                    out_pending += chunk.decode("utf-8", "replace")
                    lines = out_pending.split("\n"); out_pending = lines.pop()
                    for line in lines: on_line(line)
            if channel.recv_stderr_ready():
                chunk = channel.recv_stderr(65536); err.extend(chunk); progressed = True
                if on_line:
                    err_pending += chunk.decode("utf-8", "replace")
                    lines = err_pending.split("\n"); err_pending = lines.pop()
                    for line in lines: on_line(line)
            if channel.exit_status_ready() and not channel.recv_ready() and not channel.recv_stderr_ready():
                break
            if time.monotonic() > deadline:
                channel.close()
                raise SSHError(f"Remote command timed out after {timeout:.0f}s")
            if not progressed:
                time.sleep(0.03)
        if on_line:
            if out_pending: on_line(out_pending)
            if err_pending: on_line(err_pending)
        code = channel.recv_exit_status()
        channel.close()
        return code, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")

    def run(self, command: str, timeout: float = 120.0, check: bool = True,
            on_line: Optional[Callable[[str], None]] = None) -> tuple[int, str, str]:
        code, out, err = self._exec_stream(command, timeout, on_line=on_line)
        if check and code != 0:
            detail = err.strip() or out.strip() or f"exit code {code}"
            raise SSHError(f"Remote command failed ({code}): {detail}")
        return code, out, err

    def run_root(self, command: str, timeout: float = 900.0, check: bool = True,
                 on_line: Optional[Callable[[str], None]] = None) -> tuple[int, str, str]:
        uid = self.run("id -u", timeout=15.0)[1].strip()
        if uid == "0":
            return self.run(command, timeout=timeout, check=check, on_line=on_line)
        code, _, _ = self.run("sudo -n true", timeout=15.0, check=False)
        if code == 0:
            return self.run(f"sudo -n sh -c {shell_quote(command)}", timeout=timeout, check=check, on_line=on_line)
        sudo_password = self.config.sudo_password or self.config.password
        if not sudo_password:
            raise SSHError("Remote account is not root and passwordless sudo is unavailable. Enter a sudo password.")
        code, out, err = self._exec_stream(
            f"sudo -S -p '' sh -c {shell_quote(command)}",
            timeout,
            input_data=(sudo_password + "\n").encode(),
            on_line=on_line,
        )
        if check and code != 0:
            raise SSHError(f"Remote sudo command failed ({code}): {(err or out).strip()}")
        return code, out, err

    def upload_bytes(self, data: bytes, remote_path: str, mode: str = "600") -> None:
        # Works on embedded OpenWrt installations that expose SSH but no SFTP server.
        code, _, err = self._exec_stream(
            f"umask 077; cat > {shell_quote(remote_path)}; chmod {mode} {shell_quote(remote_path)}",
            90.0,
            input_data=data,
        )
        if code != 0:
            raise SSHError(f"Could not upload {remote_path}: {err.strip()}")

    def upload_file(self, local_path: str | Path, remote_path: str, mode: str = "600") -> None:
        self.upload_bytes(Path(local_path).read_bytes(), remote_path, mode)


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"
