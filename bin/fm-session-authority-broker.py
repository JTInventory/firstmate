#!/usr/bin/env python3
"""Per-home session authority broker using Linux AF_UNIX peer credentials."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import signal
import socket
import stat
import struct
import sys
import tempfile


MAX_BODY = 1024 * 1024
PROTOCOL_VERSION = 1


def canonical(value: str) -> str:
    return os.path.realpath(value)


def proc_fields(pid: int) -> list[str]:
    raw = Path(f"/proc/{pid}/stat").read_text()
    return raw[raw.rfind(")") + 2 :].split()


def process_start(pid: int) -> str:
    fields = proc_fields(pid)
    if len(fields) < 20:
        raise ValueError("short process stat")
    return f"proc:{fields[19]}"


def process_identity(pid: int) -> str:
    target = os.readlink(f"/proc/{pid}/exe")
    if not target.startswith("/"):
        raise ValueError("relative process identity")
    return f"exe:{target}"


def parent_pid(pid: int) -> int:
    fields = proc_fields(pid)
    if len(fields) < 2:
        raise ValueError("short process stat")
    return int(fields[1])


def process_environment(pid: int) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0"):
        if not item or b"=" not in item:
            continue
        key, value = item.split(b"=", 1)
        result[key.decode(errors="strict")] = value.decode(errors="strict")
    return result


def process_command(pid: int) -> list[str]:
    return [
        item.decode(errors="strict")
        for item in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        if item
    ]


def recv_exact(connection: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise ValueError("short broker request")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def peer_is_authorized(
    pid: int, *, home: str, task: str, script: str
) -> bool:
    try:
        command = process_command(pid)
        if len(command) < 3 or canonical(command[1]) != script or command[2] != "client":
            return False
        if canonical(os.readlink(f"/proc/{pid}/cwd")) != home:
            return False
        current = pid
        matched_secondmate = False
        for _ in range(128):
            environment = process_environment(current)
            role = environment.get("FM_AGENT_ROLE", "")
            if role == "crewmate":
                return False
            if role == "secondmate":
                if (
                    environment.get("FM_AGENT_TASK") != task
                    or canonical(environment.get("FM_AGENT_OWNER_HOME", "")) != home
                ):
                    return False
                matched_secondmate = True
            if current <= 1:
                break
            parent = parent_pid(current)
            if parent == current or parent < 1:
                return False
            current = parent
        return matched_secondmate
    except (OSError, UnicodeError, ValueError):
        return False


def write_record(
    record: Path, *, pid: int, socket_path: Path, home: str, checkout: str,
    task: str, script: str
) -> None:
    body = (
        f"version={PROTOCOL_VERSION}\n"
        f"pid={pid}\n"
        f"start={process_start(pid)}\n"
        f"identity={process_identity(pid)}\n"
        f"socket={socket_path}\n"
        f"home={home}\n"
        f"checkout={checkout}\n"
        f"task={task}\n"
        f"script={script}\n"
    )
    descriptor, temporary = tempfile.mkstemp(prefix=f"{record.name}.", dir=record.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(body)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, record)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def serve(args: argparse.Namespace) -> int:
    if not hasattr(socket, "SO_PEERCRED") or sys.platform != "linux":
        return 1
    state = Path(canonical(args.state))
    home = canonical(args.home)
    checkout = canonical(args.checkout)
    script = canonical(__file__)
    if canonical(str(state.parent)) != home or state.name != "state":
        return 1
    if not state.is_dir() or state.is_symlink() or not Path(home).is_dir():
        return 1
    socket_path = state / ".session-authority-broker.sock"
    record = state / ".session-authority-broker"
    for path in (socket_path, record):
        if path.exists() or path.is_symlink():
            return 1
    live_key = secrets.token_bytes(48)
    durable_key = secrets.token_bytes(48)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stopping = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True
        server.close()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    old_umask = os.umask(0o177)
    try:
        server.bind(str(socket_path))
    finally:
        os.umask(old_umask)
    os.chmod(socket_path, 0o600)
    server.listen(16)
    server.settimeout(1.0)
    write_record(
        record, pid=os.getpid(), socket_path=socket_path, home=home,
        checkout=checkout, task=args.task, script=script
    )
    try:
        while not stopping:
            try:
                connection, _ = server.accept()
            except socket.timeout:
                if not record.is_file() or not socket_path.exists() or not Path(home).is_dir():
                    break
                continue
            except OSError:
                if stopping:
                    break
                raise
            with connection:
                try:
                    credentials = connection.getsockopt(
                        socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
                    )
                    pid, _uid, _gid = struct.unpack("3i", credentials)
                    header = recv_exact(connection, 5)
                    kind, length = struct.unpack("!cI", header)
                    if length > MAX_BODY or kind not in (b"L", b"D"):
                        raise ValueError("invalid broker request")
                    body = recv_exact(connection, length)
                    if not peer_is_authorized(
                        pid, home=home, task=args.task, script=script
                    ):
                        connection.sendall(b"E")
                        continue
                    key = live_key if kind == b"L" else durable_key
                    digest = hmac.new(key, body, hashlib.sha256).hexdigest().encode()
                    connection.sendall(b"O" + digest)
                except (OSError, ValueError):
                    try:
                        connection.sendall(b"E")
                    except OSError:
                        pass
    finally:
        try:
            server.close()
        except OSError:
            pass
        for path in (record, socket_path):
            try:
                path.unlink()
            except OSError:
                pass
    return 0


def read_record(path: Path) -> dict[str, str]:
    metadata: dict[str, str] = {}
    file_stat = path.lstat()
    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_mode & 0o077:
        raise ValueError("unsafe broker record")
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            raise ValueError("malformed broker record")
        key, value = line.split("=", 1)
        if not key or key in metadata or "\x00" in value:
            raise ValueError("malformed broker record")
        metadata[key] = value
    required = {"version", "pid", "start", "identity", "socket", "home", "checkout", "task", "script"}
    if set(metadata) != required or metadata["version"] != str(PROTOCOL_VERSION):
        raise ValueError("malformed broker record")
    pid = int(metadata["pid"])
    if process_start(pid) != metadata["start"] or process_identity(pid) != metadata["identity"]:
        raise ValueError("stale broker record")
    command = process_command(pid)
    if len(command) < 3 or canonical(command[1]) != canonical(metadata["script"]) or command[2] != "serve":
        raise ValueError("wrong broker process")
    socket_path = Path(metadata["socket"])
    socket_stat = socket_path.lstat()
    if not stat.S_ISSOCK(socket_stat.st_mode) or socket_stat.st_mode & 0o077:
        raise ValueError("unsafe broker socket")
    if socket_path.parent != path.parent:
        raise ValueError("foreign broker socket")
    return metadata


def client(args: argparse.Namespace) -> int:
    try:
        metadata = read_record(Path(args.record))
        body = sys.stdin.buffer.read(MAX_BODY + 1)
        if len(body) > MAX_BODY:
            return 1
        kind = b"L" if args.kind == "live" else b"D"
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(metadata["socket"])
        with connection:
            connection.sendall(struct.pack("!cI", kind, len(body)) + body)
            response = recv_exact(connection, 65)
        if response[:1] != b"O" or any(value not in b"0123456789abcdef" for value in response[1:]):
            return 1
        sys.stdout.buffer.write(response[1:] + b"\n")
        return 0
    except (OSError, UnicodeError, ValueError):
        return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    server = subparsers.add_parser("serve", add_help=False)
    server.add_argument("--state", required=True)
    server.add_argument("--home", required=True)
    server.add_argument("--checkout", required=True)
    server.add_argument("--task", required=True)
    client_parser = subparsers.add_parser("client", add_help=False)
    client_parser.add_argument("--record", required=True)
    client_parser.add_argument("--kind", choices=("live", "durable"), required=True)
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    raise SystemExit(serve(arguments) if arguments.mode == "serve" else client(arguments))
