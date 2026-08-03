#!/usr/bin/env python3
"""Per-home session authority broker using Linux AF_UNIX peer credentials."""

from __future__ import annotations

import argparse
import base64
import binascii
from contextlib import contextmanager
import fcntl
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
import time


MAX_BODY = 1024 * 1024
PROTOCOL_VERSION = 1
MAX_ANCESTRY_DEPTH = 128
BROKER_REQUEST_TIMEOUT_SECONDS = 2.0
RECOVERY_LAUNCH_EVIDENCE_FD = 19


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


def process_generation(pid: int) -> tuple[str, str]:
    return process_start(pid), process_identity(pid)


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


def recv_exact(
    connection: socket.socket, length: int, deadline: float | None = None
) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        if deadline is not None:
            timeout = deadline - time.monotonic()
            if timeout <= 0:
                raise TimeoutError("broker request deadline exceeded")
            connection.settimeout(timeout)
        chunk = connection.recv(remaining)
        if not chunk:
            raise ValueError("short broker request")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def peer_is_authorized(
    pid: int, *, uid: int, gid: int, home: str, task: str, script: str,
    launch_pid: int, launch_start: str, launch_identity: str,
    broker_uid: int, broker_gid: int
) -> bool:
    try:
        if uid != broker_uid or gid != broker_gid:
            return False
        command = process_command(pid)
        if len(command) < 3 or canonical(command[1]) != script or command[2] != "client":
            return False
        if canonical(os.readlink(f"/proc/{pid}/cwd")) != home:
            return False
        peer_environment = process_environment(pid)
        owner_home = peer_environment.get("FM_AGENT_OWNER_HOME", "")
        if (
            peer_environment.get("FM_AGENT_ROLE") != "secondmate"
            or peer_environment.get("FM_AGENT_TASK") != task
            or not owner_home
            or not os.path.isabs(owner_home)
            or canonical(owner_home) != home
        ):
            return False
        peer_generation = process_generation(pid)
        current = pid
        visited: set[int] = set()
        for _ in range(MAX_ANCESTRY_DEPTH):
            ancestor_environment = process_environment(current)
            ancestor_role = ancestor_environment.get("FM_AGENT_ROLE")
            if ancestor_role != "secondmate":
                return False
            ancestor_home = ancestor_environment.get("FM_AGENT_OWNER_HOME", "")
            if (
                ancestor_environment.get("FM_AGENT_TASK") != task
                or not ancestor_home
                or not os.path.isabs(ancestor_home)
                or canonical(ancestor_home) != home
            ):
                return False
            if current == launch_pid:
                return (
                    process_generation(current) == (launch_start, launch_identity)
                    and process_generation(pid) == peer_generation
                )
            if current <= 1 or current in visited:
                return False
            visited.add(current)
            parent = parent_pid(current)
            if parent == current or parent < 1:
                return False
            current = parent
        return False
    except (OSError, UnicodeError, ValueError):
        return False


def connected_peer_matches_record(
    connection: socket.socket, metadata: dict[str, str]
) -> bool:
    credentials = connection.getsockopt(
        socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
    )
    pid, uid, gid = struct.unpack("3i", credentials)
    return (
        pid == int(metadata["pid"])
        and uid == int(metadata["uid"])
        and gid == int(metadata["gid"])
        and process_generation(pid) == (metadata["start"], metadata["identity"])
    )


def read_launch_evidence(
    fd: int, *, home: str, task: str, launch_script: str
) -> tuple[bytes, int, str, str]:
    with os.fdopen(os.dup(fd), "rb") as evidence:
        key_line = evidence.readline()
        receipt_line = evidence.readline()
        if not key_line or not receipt_line or evidence.readline():
            raise ValueError("malformed launch evidence")
    key_text = key_line.decode("ascii").strip()
    if len(key_text) < 64 or len(key_text) % 2:
        raise ValueError("malformed launch key")
    try:
        key = bytes.fromhex(key_text)
        receipt = base64.b64decode(receipt_line.strip(), validate=True)
    except (binascii.Error, ValueError, UnicodeError):
        raise ValueError("malformed launch evidence")
    lines = receipt.splitlines(keepends=True)
    if len(lines) != 7 or not receipt.endswith(b"\n"):
        raise ValueError("malformed launch receipt")
    fields: dict[str, str] = {}
    ordered = (
        "version", "task", "home", "pid", "start", "identity", "authority-hmac"
    )
    for expected, line in zip(ordered, lines):
        prefix = f"{expected}=".encode()
        if not line.startswith(prefix) or line.count(b"=") != 1:
            raise ValueError("malformed launch receipt")
        value = line[len(prefix):-1].decode("utf-8")
        if not value or "\x00" in value or expected in fields:
            raise ValueError("malformed launch receipt")
        fields[expected] = value
    if fields["version"] != "1" or fields["task"] != task:
        raise ValueError("wrong launch receipt")
    receipt_home = canonical(fields["home"])
    if receipt_home != home:
        raise ValueError("wrong launch home")
    try:
        launch_pid = int(fields["pid"])
    except ValueError as error:
        raise ValueError("malformed launch pid") from error
    if launch_pid <= 1 or len(fields["authority-hmac"]) != 64:
        raise ValueError("malformed launch receipt")
    if any(value not in "0123456789abcdef" for value in fields["authority-hmac"]):
        raise ValueError("malformed launch receipt")
    body = b"".join(lines[:6])
    expected_hmac = hmac.new(key, body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(fields["authority-hmac"], expected_hmac):
        raise ValueError("invalid launch receipt")
    if process_generation(launch_pid) != (fields["start"], fields["identity"]):
        raise ValueError("stale launch receipt")
    if canonical(os.readlink(f"/proc/{launch_pid}/cwd")) != home:
        raise ValueError("wrong launch cwd")
    command = process_command(launch_pid)
    if len(command) < 2 or canonical(command[1]) != launch_script:
        raise ValueError("wrong launch process")
    return key, launch_pid, fields["start"], fields["identity"]


def derive_broker_durable_key(
    root_key: bytes, *, task: str, home: str, launch_pid: int,
    launch_start: str, launch_identity: str, launch_script: str
) -> bytes:
    context = b"\0".join(
        (
            b"firstmate/session-authority-broker/durable/v1",
            task.encode("utf-8"),
            home.encode("utf-8"),
            str(launch_pid).encode("ascii"),
            launch_start.encode("utf-8"),
            launch_identity.encode("utf-8"),
            launch_script.encode("utf-8"),
        )
    )
    return hmac.new(root_key, context, hashlib.sha256).digest()


def write_record(
    record: Path, *, pid: int, socket_address: str, home: str, checkout: str,
    task: str, script: str, launch_pid: int, launch_start: str,
    launch_identity: str, launch_script: str, uid: int, gid: int
) -> None:
    body = (
        f"version={PROTOCOL_VERSION}\n"
        f"pid={pid}\n"
        f"start={process_start(pid)}\n"
        f"identity={process_identity(pid)}\n"
        f"socket={socket_address}\n"
        f"home={home}\n"
        f"checkout={checkout}\n"
        f"task={task}\n"
        f"script={script}\n"
        f"uid={uid}\n"
        f"gid={gid}\n"
        f"launch-pid={launch_pid}\n"
        f"launch-start={launch_start}\n"
        f"launch-identity={launch_identity}\n"
        f"launch-script={launch_script}\n"
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


@contextmanager
def record_lock(path: Path, *, blocking: bool):
    lock_path = Path(f"{path}.lock")
    descriptor = os.open(
        lock_path,
        os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        os.fchmod(descriptor, 0o600)
        lock_stat = os.fstat(descriptor)
        if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_mode & 0o077:
            raise ValueError("unsafe broker record lock")
        flags = fcntl.LOCK_EX
        if not blocking:
            flags |= fcntl.LOCK_NB
        try:
            fcntl.flock(descriptor, flags)
        except BlockingIOError:
            yield None
            return
        yield descriptor
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def serve(args: argparse.Namespace) -> int:
    if not hasattr(socket, "SO_PEERCRED") or sys.platform != "linux":
        return 1
    state = Path(canonical(args.state))
    home = canonical(args.home)
    checkout = canonical(args.checkout)
    script = canonical(__file__)
    implementation_checkout = canonical(str(Path(script).parent.parent))
    if checkout != implementation_checkout:
        return 1
    launch_script = canonical(args.launch_script)
    if canonical(str(state.parent)) != home or state.name != "state":
        return 1
    if not state.is_dir() or state.is_symlink() or not Path(home).is_dir():
        return 1
    try:
        durable_root_key, launch_pid, launch_start, launch_identity = read_launch_evidence(
            args.launch_evidence_fd, home=home, task=args.task,
            launch_script=launch_script
        )
    except (OSError, UnicodeError, ValueError, struct.error):
        return 1
    record = state / ".session-authority-broker"
    if record.exists() or record.is_symlink():
        return 1
    durable_key = derive_broker_durable_key(
        durable_root_key, task=args.task, home=home, launch_pid=launch_pid,
        launch_start=launch_start, launch_identity=launch_identity,
        launch_script=launch_script
    )
    socket_name = f"firstmate-{os.getpid()}-{secrets.token_hex(16)}"
    socket_address = f"abstract:{socket_name}"
    bind_address = f"\0{socket_name}"
    live_key = secrets.token_bytes(48)
    broker_uid = os.geteuid()
    broker_gid = os.getegid()
    broker_pid = os.getpid()
    broker_start = process_start(broker_pid)
    broker_identity = process_identity(broker_pid)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stopping = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True
        server.close()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with record_lock(record, blocking=True):
        if record.exists() or record.is_symlink():
            return 1
        server.bind(bind_address)
        server.listen(16)
        server.settimeout(1.0)
        write_record(
            record, pid=broker_pid, socket_address=socket_address, home=home,
            checkout=checkout, task=args.task, script=script, launch_pid=launch_pid,
            launch_start=launch_start, launch_identity=launch_identity,
            launch_script=launch_script, uid=broker_uid, gid=broker_gid
        )
    try:
        while not stopping:
            try:
                connection, _ = server.accept()
            except socket.timeout:
                if not record.is_file() or record.is_symlink() or not Path(home).is_dir():
                    break
                if launch_process_state(
                    launch_pid, launch_start, launch_identity, launch_script
                ) == "dead":
                    break
                continue
            except OSError:
                if stopping:
                    break
                raise
            with connection:
                try:
                    request_deadline = time.monotonic() + BROKER_REQUEST_TIMEOUT_SECONDS
                    credentials = connection.getsockopt(
                        socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
                    )
                    pid, uid, gid = struct.unpack("3i", credentials)
                    header = recv_exact(connection, 5, request_deadline)
                    kind, length = struct.unpack("!cI", header)
                    if length > MAX_BODY or kind not in (b"L", b"D"):
                        raise ValueError("invalid broker request")
                    body = recv_exact(connection, length, request_deadline)
                    if not peer_is_authorized(
                        pid, uid=uid, gid=gid, home=home, task=args.task, script=script,
                        launch_pid=launch_pid, launch_start=launch_start,
                        launch_identity=launch_identity, broker_uid=broker_uid,
                        broker_gid=broker_gid
                    ):
                        connection.sendall(b"E")
                        continue
                    key = live_key if kind == b"L" else durable_key
                    digest = hmac.new(key, body, hashlib.sha256).hexdigest().encode()
                    connection.sendall(b"O" + digest)
                except (OSError, struct.error, ValueError):
                    try:
                        connection.sendall(b"E")
                    except OSError:
                        pass
    finally:
        try:
            server.close()
        except OSError:
            pass
        unlink_owned_record(
            record,
            {
                "pid": str(broker_pid),
                "start": broker_start,
                "identity": broker_identity,
                "socket": socket_address,
                "home": home,
                "checkout": checkout,
                "task": args.task,
                "script": script,
                "launch-pid": str(launch_pid),
                "launch-start": launch_start,
                "launch-identity": launch_identity,
                "launch-script": launch_script,
                "uid": str(broker_uid),
                "gid": str(broker_gid),
            },
        )
    return 0


def read_record_shape(path: Path) -> dict[str, str]:
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
    required = {
        "version", "pid", "start", "identity", "socket", "home", "checkout",
        "task", "script", "uid", "gid", "launch-pid", "launch-start",
        "launch-identity", "launch-script"
    }
    if set(metadata) != required or metadata["version"] != str(PROTOCOL_VERSION):
        raise ValueError("malformed broker record")
    pid = int(metadata["pid"])
    if pid <= 1:
        raise ValueError("malformed broker record")
    for key in ("uid", "gid"):
        if int(metadata[key]) < 0:
            raise ValueError("malformed broker record")
    if int(metadata["launch-pid"]) <= 1:
        raise ValueError("malformed broker record")
    if canonical(metadata["launch-script"]) != metadata["launch-script"]:
        raise ValueError("malformed launch script")
    socket_value = metadata["socket"]
    if socket_value.startswith("abstract:"):
        socket_name = socket_value.removeprefix("abstract:")
        if (
            not socket_name
            or len(socket_name.encode()) > 107
            or any(value not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._" for value in socket_name)
        ):
            raise ValueError("unsafe abstract broker socket")
    else:
        socket_path = Path(socket_value)
        socket_stat = socket_path.lstat()
        if not stat.S_ISSOCK(socket_stat.st_mode) or socket_stat.st_mode & 0o077:
            raise ValueError("unsafe broker socket")
        if socket_path.parent != path.parent:
            raise ValueError("foreign broker socket")
    return metadata


def read_record(path: Path) -> dict[str, str]:
    metadata = read_record_shape(path)
    pid = int(metadata["pid"])
    try:
        generation = process_generation(pid)
    except (OSError, ValueError) as error:
        raise ValueError("stale broker record") from error
    if generation != (metadata["start"], metadata["identity"]):
        raise ValueError("stale broker record")
    command = process_command(pid)
    if len(command) < 3 or canonical(command[1]) != canonical(metadata["script"]) or command[2] != "serve":
        raise ValueError("wrong broker process")
    return metadata


def process_generation_for_recovery(pid: int) -> tuple[str, str] | None:
    proc_path = Path(f"/proc/{pid}")
    try:
        proc_path.stat()
    except FileNotFoundError:
        return None
    generation_error: OSError | ValueError | None = None
    try:
        return process_generation(pid)
    except (OSError, ValueError) as error:
        generation_error = error
    try:
        proc_path.stat()
    except FileNotFoundError:
        return None
    if generation_error is not None:
        raise generation_error
    raise ValueError("unreadable process generation")


def launch_process_state(
    pid: int, start: str, identity: str, launch_script: str
) -> str:
    try:
        generation = process_generation_for_recovery(pid)
    except (OSError, UnicodeError, ValueError):
        return "unknown"
    if generation is None or generation != (start, identity):
        return "dead"
    try:
        command = process_command(pid)
    except (OSError, UnicodeError, ValueError):
        return "unknown"
    if len(command) >= 2 and canonical(command[1]) == launch_script:
        return "current"
    return "unknown"


def unlink_owned_record(
    path: Path, expected: dict[str, str], expected_stat: os.stat_result | None = None,
    *, lock_held: bool = False
) -> bool:
    if not lock_held:
        with record_lock(path, blocking=False) as lock:
            if lock is None:
                return False
            return unlink_owned_record(
                path, expected, expected_stat=expected_stat, lock_held=True
            )
    try:
        initial_stat = path.lstat()
        if expected_stat is not None and (
            initial_stat.st_dev != expected_stat.st_dev
            or initial_stat.st_ino != expected_stat.st_ino
        ):
            return False
        metadata = read_record_shape(path)
        if any(metadata.get(key) != value for key, value in expected.items()):
            return False
        final_stat = path.lstat()
        if (
            initial_stat.st_dev != final_stat.st_dev
            or initial_stat.st_ino != final_stat.st_ino
        ):
            return False
        if expected_stat is not None and (
            final_stat.st_dev != expected_stat.st_dev
            or final_stat.st_ino != expected_stat.st_ino
        ):
            return False
        path.unlink()
        return True
    except (FileNotFoundError, OSError, UnicodeError, ValueError):
        return False


def broker_command_matches(
    command: list[str], *, script: str, state: str, home: str,
    checkout: str, task: str, launch_script: str
) -> bool:
    return (
        len(command) == 15
        and canonical(command[1]) == script
        and command[2] == "serve"
        and command[3] == "--state"
        and canonical(command[4]) == state
        and command[5] == "--home"
        and canonical(command[6]) == home
        and command[7] == "--checkout"
        and canonical(command[8]) == checkout
        and command[9] == "--task"
        and command[10] == task
        and command[11] == "--launch-evidence-fd"
        and command[12] == str(RECOVERY_LAUNCH_EVIDENCE_FD)
        and command[13] == "--launch-script"
        and canonical(command[14]) == launch_script
    )


def stop_recorded_broker(
    pid: int, generation: tuple[str, str], *, script: str, state: str,
    home: str, checkout: str, task: str, launch_script: str
) -> bool:
    current = process_generation_for_recovery(pid)
    if current is None or current != generation:
        return current is None
    command = process_command(pid)
    if (
        len(command) < 2
        or not broker_command_matches(
            command,
            script=script,
            state=state,
            home=home,
            checkout=checkout,
            task=task,
            launch_script=launch_script,
        )
    ):
        return False
    for number in (signal.SIGTERM, signal.SIGKILL):
        current = process_generation_for_recovery(pid)
        if current is None:
            return True
        if current != generation:
            return False
        try:
            command = process_command(pid)
        except (OSError, UnicodeError, ValueError):
            return False
        if not broker_command_matches(
            command,
            script=script,
            state=state,
            home=home,
            checkout=checkout,
            task=task,
            launch_script=launch_script,
        ):
            return False
        os.kill(pid, number)
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            current = process_generation_for_recovery(pid)
            if current is None:
                return True
            if current != generation:
                return False
            time.sleep(0.02)
    return False


def recover_stale(args: argparse.Namespace) -> int:
    if not sys.platform.startswith("linux") or not hasattr(socket, "SO_PEERCRED"):
        return 1
    record = Path(args.record)
    try:
        with record_lock(record, blocking=True):
            record_stat = record.lstat()
            metadata = read_record_shape(record)
            expected_home = canonical(metadata["home"])
            expected_script = canonical(__file__)
            expected_checkout = canonical(str(Path(expected_script).parent.parent))
            expected_launch_script = canonical(metadata["launch-script"])
            expected_state = canonical(str(record.parent))
            if (
                metadata["home"] != expected_home
                or metadata["checkout"] != expected_checkout
                or metadata["script"] != expected_script
                or metadata["launch-script"] != expected_launch_script
                or expected_launch_script != canonical(
                    f"{expected_home}/bin/fm-session-authority-exec.sh"
                )
                or record.parent != Path(expected_home) / "state"
            ):
                return 1
            _, launch_pid, _, _ = read_launch_evidence(
                RECOVERY_LAUNCH_EVIDENCE_FD,
                home=expected_home,
                task=metadata["task"],
                launch_script=expected_launch_script,
            )
            if launch_pid != os.getppid():
                return 1
            launch_generation = process_generation_for_recovery(
                int(metadata["launch-pid"])
            )
            if launch_generation == (
                metadata["launch-start"], metadata["launch-identity"]
            ):
                return 1
            pid = int(metadata["pid"])
            generation = process_generation_for_recovery(pid)
            if generation is not None and not stop_recorded_broker(
                pid,
                (metadata["start"], metadata["identity"]),
                script=expected_script,
                state=expected_state,
                home=expected_home,
                checkout=expected_checkout,
                task=metadata["task"],
                launch_script=expected_launch_script,
            ):
                return 1
            if not record.exists() and not record.is_symlink():
                return 0
            return int(
                not unlink_owned_record(
                    record,
                    metadata,
                    expected_stat=record_stat,
                    lock_held=True,
                )
            )
    except FileNotFoundError:
        return 0 if not record.exists() and not record.is_symlink() else 1
    except (OSError, UnicodeError, ValueError):
        return 1


def client(args: argparse.Namespace) -> int:
    try:
        metadata = read_record(Path(args.record))
        body = sys.stdin.buffer.read(MAX_BODY + 1)
        if len(body) > MAX_BODY:
            return 1
        kind = b"L" if args.kind == "live" else b"D"
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        request_deadline = time.monotonic() + BROKER_REQUEST_TIMEOUT_SECONDS
        connection.settimeout(BROKER_REQUEST_TIMEOUT_SECONDS)
        socket_value = metadata["socket"]
        connection.connect(
            f"\0{socket_value.removeprefix('abstract:')}"
            if socket_value.startswith("abstract:")
            else socket_value
        )
        with connection:
            if not connected_peer_matches_record(connection, metadata):
                return 1
            timeout = request_deadline - time.monotonic()
            if timeout <= 0:
                return 1
            connection.settimeout(timeout)
            connection.sendall(struct.pack("!cI", kind, len(body)) + body)
            response = recv_exact(
                connection, 65, request_deadline
            )
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
    server.add_argument("--launch-evidence-fd", type=int, required=True)
    server.add_argument("--launch-script", required=True)
    recovery = subparsers.add_parser("recover-stale", add_help=False)
    recovery.add_argument("--record", required=True)
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    if arguments.mode == "serve":
        result = serve(arguments)
    elif arguments.mode == "client":
        result = client(arguments)
    else:
        result = recover_stale(arguments)
    raise SystemExit(result)
