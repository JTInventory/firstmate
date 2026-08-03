#!/usr/bin/env python3
"""Per-home session authority broker using Linux AF_UNIX peer credentials."""

from __future__ import annotations

import argparse
import base64
import binascii
import ctypes
import errno
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
import subprocess
import sys
import tempfile
import time


MAX_BODY = 1024 * 1024
PROTOCOL_VERSION = 1
MAX_ANCESTRY_DEPTH = 128
BROKER_REQUEST_TIMEOUT_SECONDS = 2.0
RECOVERY_LAUNCH_EVIDENCE_FD = 19
AUTHORITY_SERIALIZATION_FD = 18
MAX_RECOVERY_QUARANTINES = 4
QUARANTINE_RECEIPT_SUFFIX = ".receipt"
QUARANTINE_PROOF_SUFFIX = ".proof"
QUARANTINE_RECEIPT_TEMP_SUFFIX = ".receipt-tmp"
QUARANTINE_IDENTITY_SUFFIX = ".identity"
AUTHORITY_LOCK_TIMEOUT_SECONDS = 0.25
MAX_QUARANTINE_RECEIPT_BYTES = 4096


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


def verify_embedded_signature(
    public_key: str, signature: str, body: bytes
) -> bool:
    try:
        public_bytes = base64.b64decode(public_key, validate=True)
        signature_bytes = base64.b64decode(signature, validate=True)
    except (binascii.Error, UnicodeError):
        return False
    with tempfile.TemporaryDirectory(prefix="fm-authority-proof-") as directory:
        root = Path(directory)
        public_file = root / "public"
        signature_file = root / "signature"
        body_file = root / "body"
        public_file.write_bytes(public_bytes)
        signature_file.write_bytes(signature_bytes)
        body_file.write_bytes(body)
        result = subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-verify", str(public_file),
                "-signature", str(signature_file), str(body_file),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0


def embedded_fields(
    data: bytes, ordered: tuple[str, ...]
) -> tuple[dict[str, str], list[bytes]]:
    lines = data.splitlines(keepends=True)
    if len(lines) != len(ordered) or not data.endswith(b"\n"):
        raise ValueError("malformed enrollment proof")
    fields: dict[str, str] = {}
    for expected, line in zip(ordered, lines):
        prefix = f"{expected}=".encode()
        if not line.startswith(prefix) or expected in fields:
            raise ValueError("malformed enrollment proof")
        value = line[len(prefix):-1].decode("utf-8")
        if not value or "\x00" in value or "\r" in value:
            raise ValueError("malformed enrollment proof")
        fields[expected] = value
    return fields, lines


def read_launch_evidence(
    fd: int, *, home: str, task: str, launch_script: str
) -> tuple[bytes, int, str, str]:
    with os.fdopen(os.dup(fd), "rb") as evidence:
        proof_lines = [evidence.readline() for _ in range(6)]
        if any(not line for line in proof_lines) or evidence.readline():
            raise ValueError("malformed launch evidence")
    key_line, receipt_line, ticket_line, accepted_line, final_line, consumer_line = (
        proof_lines
    )
    key_text = key_line.decode("ascii").strip()
    if len(key_text) < 64 or len(key_text) % 2:
        raise ValueError("malformed launch key")
    try:
        key = bytes.fromhex(key_text)
        receipt = base64.b64decode(receipt_line.strip(), validate=True)
    except (binascii.Error, ValueError, UnicodeError):
        raise ValueError("malformed launch evidence")
    lines = receipt.splitlines(keepends=True)
    if len(lines) != 8 or not receipt.endswith(b"\n"):
        raise ValueError("malformed launch receipt")
    fields: dict[str, str] = {}
    ordered = (
        "version", "task", "home", "pid", "start", "identity", "nonce",
        "authority-hmac"
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
    if (
        launch_pid <= 1
        or len(fields["nonce"]) != 64
        or len(fields["authority-hmac"]) != 64
    ):
        raise ValueError("malformed launch receipt")
    if any(
        value not in "0123456789abcdef"
        for value in fields["nonce"] + fields["authority-hmac"]
    ):
        raise ValueError("malformed launch receipt")
    body = b"".join(lines[:7])
    expected_hmac = hmac.new(key, body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(fields["authority-hmac"], expected_hmac):
        raise ValueError("invalid launch receipt")
    if process_generation(launch_pid) != (fields["start"], fields["identity"]):
        raise ValueError("stale launch receipt")
    if parent_pid(os.getpid()) != launch_pid:
        raise ValueError("untrusted broker parent")
    if canonical(os.readlink(f"/proc/{launch_pid}/cwd")) != home:
        raise ValueError("wrong launch cwd")
    command = process_command(launch_pid)
    launch_path = Path(launch_script)
    if (
        not launch_path.is_file()
        or launch_path.is_symlink()
        or len(command) < 2
        or canonical(command[1]) != launch_script
    ):
        raise ValueError("wrong launch process")
    launch_identity = fields["identity"]
    if not launch_identity.startswith("exe:"):
        raise ValueError("untrusted launch executable")
    launch_executable = Path(launch_identity[4:])
    executable_stat = launch_executable.stat()
    if (
        launch_executable.name not in {"bash", "sh"}
        or executable_stat.st_uid != 0
        or executable_stat.st_mode & 0o022
    ):
        raise ValueError("untrusted launch executable")
    launch_environment = process_environment(launch_pid)
    owner_home = launch_environment.get("FM_AGENT_OWNER_HOME", "")
    if (
        launch_environment.get("FM_SESSION_AUTHORITY_WRAPPER_AUTHORIZED") != "1"
        or launch_environment.get("FM_AGENT_ROLE") != "secondmate"
        or launch_environment.get("FM_AGENT_TASK") != task
        or not os.path.isabs(owner_home)
        or canonical(owner_home) != home
        or launch_environment.get("FM_SESSION_ENROLLMENT_NONCE") != fields["nonce"]
    ):
        raise ValueError("untrusted launch provenance")
    try:
        ticket = base64.b64decode(ticket_line.strip(), validate=True)
        accepted = base64.b64decode(accepted_line.strip(), validate=True)
        final = base64.b64decode(final_line.strip(), validate=True)
        consumer_public_key = consumer_line.strip().decode("ascii")
    except (binascii.Error, UnicodeError):
        raise ValueError("malformed enrollment proof")
    ticket_fields, ticket_lines = embedded_fields(
        ticket,
        (
            "version", "role", "task", "home", "issuer-home",
            "issuer-authority", "nonce", "broker-pid", "broker-start",
            "broker-identity", "broker-script", "authority-fd",
            "authority-descriptor", "signer-pid", "signer-start",
            "signer-identity", "public-key", "public-key-sha256",
            "endpoint-pid", "endpoint-start", "endpoint-identity", "signature",
        ),
    )
    if (
        ticket_fields["version"] != "5"
        or ticket_fields["role"] != "secondmate"
        or ticket_fields["task"] != task
        or canonical(ticket_fields["home"]) != home
        or canonical(ticket_fields["issuer-home"]) == home
        or len(ticket_fields["nonce"]) != 64
        or any(c not in "0123456789abcdef" for c in ticket_fields["nonce"])
        or ticket_fields["endpoint-pid"] != str(launch_pid)
        or ticket_fields["endpoint-start"] != fields["start"]
        or ticket_fields["endpoint-identity"] != fields["identity"]
        or ticket_fields["public-key-sha256"]
        != hashlib.sha256(
            base64.b64decode(ticket_fields["public-key"], validate=True)
        ).hexdigest()
        or not verify_embedded_signature(
            ticket_fields["public-key"], ticket_fields["signature"],
            b"".join(ticket_lines[:21]),
        )
    ):
        raise ValueError("untrusted enrollment ticket")
    issuer_authority = Path(canonical(ticket_fields["issuer-home"])) / "state" / ".session-authority"
    if (
        issuer_authority.is_symlink()
        or not issuer_authority.is_file()
        or ticket_fields["issuer-authority"]
        != hashlib.sha256(issuer_authority.read_bytes()).hexdigest()
    ):
        raise ValueError("untrusted enrollment authority")
    accepted_fields, accepted_lines = embedded_fields(
        accepted,
        (
            "version", "signer-pid", "nonce", "consumer-pid", "consumer-start",
            "consumer-public-key-sha256", "signature",
        ),
    )
    if (
        accepted_fields["version"] != "2"
        or accepted_fields["signer-pid"] != ticket_fields["signer-pid"]
        or accepted_fields["nonce"] != ticket_fields["nonce"]
        or accepted_fields["consumer-pid"] != str(launch_pid)
        or accepted_fields["consumer-start"] != fields["start"]
        or not verify_embedded_signature(
            ticket_fields["public-key"], accepted_fields["signature"],
            b"".join(accepted_lines[:6]),
        )
    ):
        raise ValueError("untrusted enrollment acceptance")
    try:
        consumer_key_bytes = base64.b64decode(consumer_public_key, validate=True)
    except (binascii.Error, UnicodeError):
        raise ValueError("malformed enrollment consumer key")
    if hashlib.sha256(consumer_key_bytes).hexdigest() != \
        accepted_fields["consumer-public-key-sha256"]:
        raise ValueError("untrusted enrollment consumer key")
    final_fields, final_lines = embedded_fields(
        final,
        (
            "version", "stage", "signer-pid", "nonce", "consumer-pid",
            "consumer-start", "acceptance-sha256", "consumer-public-key-sha256",
            "signature",
        ),
    )
    if (
        final_fields["version"] != "2"
        or final_fields["stage"] != "final"
        or final_fields["signer-pid"] != accepted_fields["signer-pid"]
        or final_fields["nonce"] != fields["nonce"]
        or final_fields["consumer-pid"] != str(launch_pid)
        or final_fields["consumer-start"] != fields["start"]
        or final_fields["acceptance-sha256"]
        != hashlib.sha256(accepted).hexdigest()
        or final_fields["consumer-public-key-sha256"]
        != accepted_fields["consumer-public-key-sha256"]
        or not verify_embedded_signature(
            consumer_public_key, final_fields["signature"],
            b"".join(final_lines[:8]),
        )
    ):
        raise ValueError("untrusted enrollment final receipt")
    return key, launch_pid, fields["start"], fields["identity"]


def derive_broker_durable_key(
    root_key: bytes, *, task: str, home: str, launch_pid: int,
    launch_start: str, launch_identity: str, launch_script: str
) -> bytes:
    context = b"\0".join(
        (
            b"firstmate/session-authority-broker/durable/v2",
            task.encode("utf-8"),
            home.encode("utf-8"),
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
def record_lock(
    path: Path, *, blocking: bool, expected_stat: os.stat_result | None = None,
    authority_home: str | None = None, authority_task: str | None = None,
    launch_script: str | None = None,
    launch_evidence: tuple[bytes, int, str, str] | None = None,
):
    if authority_home is None:
        descriptor = open_record_lock(
            path, blocking=blocking, expected_stat=expected_stat
        )
    else:
        descriptor = open_authority_record_lock(
            blocking=blocking,
            state=Path(authority_home) / "state",
            home=authority_home,
            task=authority_task,
            launch_script=launch_script,
            launch_evidence=launch_evidence,
        )
    try:
        yield descriptor
    finally:
        close_record_lock(descriptor)


def open_record_lock(
    path: Path, *, blocking: bool, expected_stat: os.stat_result | None = None
) -> int | None:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        lock_stat = os.fstat(descriptor)
        if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_mode & 0o077:
            raise ValueError("unsafe broker record lock")
        if expected_stat is not None and (
            lock_stat.st_dev != expected_stat.st_dev
            or lock_stat.st_ino != expected_stat.st_ino
        ):
            os.close(descriptor)
            return None
        flags = fcntl.LOCK_EX
        if not blocking:
            flags |= fcntl.LOCK_NB
        try:
            fcntl.flock(descriptor, flags)
        except BlockingIOError:
            os.close(descriptor)
            return None
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


class AuthorityRecordLock:
    def __init__(self, fd: int):
        self.fd = fd
        self.closed = False

    def fileno(self) -> int:
        return self.fd


def close_record_lock(
    descriptor: int | AuthorityRecordLock | socket.socket | None
) -> None:
    if descriptor is None:
        return
    if isinstance(descriptor, AuthorityRecordLock):
        if descriptor.closed:
            return
        try:
            fcntl.flock(descriptor.fd, fcntl.LOCK_UN)
        except OSError:
            pass
        finally:
            descriptor.closed = True
            try:
                os.close(descriptor.fd)
            except OSError:
                pass
        return
    if isinstance(descriptor, socket.socket):
        try:
            descriptor.sendall(b"RELEASE\n")
        except OSError:
            pass
        descriptor.close()
        return
    os.close(descriptor)


def authority_admission_path(
    state: Path, launch_evidence: tuple[bytes, int, str, str]
) -> Path:
    root_key = launch_evidence[0]
    digest = hmac.new(
        root_key,
        b"firstmate/session-authority-broker/admission/v1\0"
        + canonical(str(state)).encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return state / f".session-authority-admission-{digest}.lock"


def open_authority_admission_lock(
    state: Path, launch_evidence: tuple[bytes, int, str, str]
) -> tuple[int, Path] | None:
    path = authority_admission_path(state, launch_evidence)
    try:
        descriptor = os.open(
            path,
            os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
        descriptor_stat = os.fstat(descriptor)
        if (
            not stat.S_ISREG(descriptor_stat.st_mode)
            or descriptor_stat.st_uid != os.geteuid()
            or descriptor_stat.st_mode & 0o077
        ):
            os.close(descriptor)
            return None
        return descriptor, path
    except OSError:
        return None


def open_authority_record_lock(
    *, blocking: bool, state: Path | None = None, home: str | None = None,
    task: str | None = None,
    launch_script: str | None = None,
    launch_evidence: tuple[bytes, int, str, str] | None = None
) -> AuthorityRecordLock | None:
    if (
        state is None or home is None or task is None or launch_script is None
        or launch_evidence is None
    ):
        return None
    if not state.is_dir() or state.is_symlink() or canonical(str(state.parent)) != home:
        return None
    if not task or canonical(launch_script) != canonical(
        f"{home}/bin/fm-session-authority-exec.sh"
    ):
        return None
    opened = open_authority_admission_lock(state, launch_evidence)
    if opened is None:
        return None
    descriptor, path = opened
    try:
        if descriptor != AUTHORITY_SERIALIZATION_FD:
            os.dup2(descriptor, AUTHORITY_SERIALIZATION_FD)
            os.close(descriptor)
            descriptor = AUTHORITY_SERIALIZATION_FD
        lock = acquire_authority_record_lock(
            descriptor, blocking=blocking, expected_path=path
        )
        if lock is None:
            os.close(descriptor)
        return lock
    except OSError:
        try:
            os.close(descriptor)
        except OSError:
            pass
        return None


def acquire_authority_record_lock(
    fd: int, *, blocking: bool, expected_path: Path | None = None
) -> AuthorityRecordLock | None:
    if fd != AUTHORITY_SERIALIZATION_FD:
        return None
    try:
        descriptor_stat = os.fstat(fd)
        if (
            not stat.S_ISREG(descriptor_stat.st_mode)
            or descriptor_stat.st_uid != os.geteuid()
            or descriptor_stat.st_mode & 0o077
        ):
            return None
        if expected_path is not None:
            fd_path = os.path.realpath(f"/proc/self/fd/{fd}")
            if fd_path != canonical(str(expected_path)):
                return None
    except OSError:
        return None
    deadline = time.monotonic() + AUTHORITY_LOCK_TIMEOUT_SECONDS
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return AuthorityRecordLock(fd)
        except OSError as error:
            if error.errno not in {errno.EACCES, errno.EAGAIN}:
                return None
            if not blocking or time.monotonic() >= deadline:
                return None
            time.sleep(0.01)


def inherited_authority_record_lock(
    fd: int, *, home: str, task: str,
    launch_script: str,
    launch_evidence: tuple[bytes, int, str, str]
) -> AuthorityRecordLock | None:
    if fd != AUTHORITY_SERIALIZATION_FD or not task or canonical(
        launch_script
    ) != canonical(f"{home}/bin/fm-session-authority-exec.sh"):
        return None
    return acquire_authority_record_lock(
        fd,
        blocking=False,
        expected_path=authority_admission_path(
            Path(canonical(home)) / "state", launch_evidence
        ),
    )


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
    record = state / ".session-authority-broker"
    try:
        launch_evidence = read_launch_evidence(
            args.launch_evidence_fd, home=home, task=args.task,
            launch_script=launch_script
        )
    except (OSError, UnicodeError, ValueError, struct.error):
        return 1
    record_lock_argument = getattr(args, "record_lock_fd", -1)
    if record_lock_argument >= 0:
        if record_lock_argument != AUTHORITY_SERIALIZATION_FD:
            return 1
        record_lock_fd = inherited_authority_record_lock(
            record_lock_argument, home=home, task=args.task,
            launch_script=launch_script,
            launch_evidence=launch_evidence
        )
    else:
        record_lock_fd = open_authority_record_lock(
            blocking=False, state=state, home=home, task=args.task,
            launch_script=launch_script, launch_evidence=launch_evidence
        )
    if record_lock_fd is None:
        return 1
    try:
        return serve_locked(
            args, state=state, home=home, checkout=checkout, script=script,
            launch_script=launch_script, record=record, lock=record_lock_fd,
            launch_evidence=launch_evidence
        )
    finally:
        close_record_lock(record_lock_fd)


def read_evidence_bytes(fd: int) -> bytes:
    chunks: list[bytes] = []
    length = 0
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        length += len(chunk)
        if length > 1024 * 1024:
            raise ValueError("oversized launch evidence")
        chunks.append(chunk)
    if not chunks:
        raise ValueError("empty launch evidence")
    return b"".join(chunks)


def install_evidence_bytes(data: bytes) -> None:
    read_fd, write_fd = os.pipe()
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(write_fd, data[offset:])
    except BaseException:
        os.close(read_fd)
        raise
    finally:
        os.close(write_fd)
    try:
        os.dup2(read_fd, RECOVERY_LAUNCH_EVIDENCE_FD, inheritable=True)
    finally:
        os.close(read_fd)


def supervise(args: argparse.Namespace) -> int:
    record_lock_fd: AuthorityRecordLock | None = None
    try:
        evidence = read_evidence_bytes(args.launch_evidence_fd)
        if args.launch_evidence_fd != RECOVERY_LAUNCH_EVIDENCE_FD:
            os.close(args.launch_evidence_fd)
        install_evidence_bytes(evidence)
        launch_evidence = read_launch_evidence(
            RECOVERY_LAUNCH_EVIDENCE_FD,
            home=canonical(args.home),
            task=args.task,
            launch_script=canonical(args.launch_script),
        )
        state = Path(canonical(args.state))
        home = canonical(args.home)
        launch_script = canonical(args.launch_script)
        record_lock_fd = open_authority_record_lock(
            blocking=False, state=state, home=home, task=args.task,
            launch_script=launch_script, launch_evidence=launch_evidence
        )
        if record_lock_fd is None:
            return 1
        recovery_args = argparse.Namespace(
            record=str(state / ".session-authority-broker"),
            state=str(state),
            home=home,
            checkout=canonical(args.checkout),
            task=args.task,
            launch_script=launch_script,
        )
        if recover_stale_locked(
            recovery_args, launch_evidence=launch_evidence, lease=record_lock_fd
        ) != 0:
            return 1
        os.set_inheritable(AUTHORITY_SERIALIZATION_FD, True)
        install_evidence_bytes(evidence)
        os.execv(
            sys.executable,
            [
                sys.executable,
                canonical(__file__),
                "serve",
                "--state", args.state,
                "--home", args.home,
                "--checkout", args.checkout,
                "--task", args.task,
                "--record-lock-fd", str(AUTHORITY_SERIALIZATION_FD),
                "--launch-evidence-fd", str(RECOVERY_LAUNCH_EVIDENCE_FD),
                "--launch-script", args.launch_script,
            ],
        )
    except (OSError, UnicodeError, ValueError, struct.error):
        return 1
    finally:
        close_record_lock(record_lock_fd)
    return 1


def serve_locked(
    args: argparse.Namespace, *, state: Path, home: str, checkout: str,
    script: str, launch_script: str, record: Path,
    lock: AuthorityRecordLock | None,
    launch_evidence: tuple[bytes, int, str, str]
) -> int:
    durable_root_key, launch_pid, launch_start, launch_identity = launch_evidence
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
    try:
        server.bind(bind_address)
        server.listen(16)
        server.settimeout(1.0)
        write_record(
            record, pid=broker_pid, socket_address=socket_address, home=home,
            checkout=checkout, task=args.task, script=script, launch_pid=launch_pid,
            launch_start=launch_start, launch_identity=launch_identity,
            launch_script=launch_script, uid=broker_uid, gid=broker_gid
        )
        expected_record = {
            "version": str(PROTOCOL_VERSION),
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
        }
        if read_record_shape(record) != expected_record:
            return 1
        if not cleanup_recovery_quarantines(
            record,
            {
                "home": home,
                "checkout": checkout,
                "task": args.task,
                "script": script,
                "launch-script": launch_script,
                "uid": str(broker_uid),
                "gid": str(broker_gid),
            },
            durable_key,
        ):
            return 1
        close_record_lock(lock)
        lock = None
        while not stopping:
            if not record.is_file() or record.is_symlink() or not Path(home).is_dir():
                break
            if launch_process_state(
                launch_pid, launch_start, launch_identity, launch_script
            ) == "dead":
                break
            try:
                connection, _ = server.accept()
            except socket.timeout:
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


def rename_noreplace(source: Path, target: Path) -> None:
    try:
        renameat2 = ctypes.CDLL(None, use_errno=True).renameat2
    except AttributeError as error:
        raise OSError(errno.ENOSYS, "renameat2 unavailable") from error
    renameat2.argtypes = [
        ctypes.c_int, ctypes.c_char_p,
        ctypes.c_int, ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    if renameat2(
        -100,
        os.fsencode(source),
        -100,
        os.fsencode(target),
        1,
    ) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), str(source))


def record_metadata_digest(metadata: dict[str, str]) -> str:
    body = "".join(f"{key}={metadata[key]}\n" for key in sorted(metadata))
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def quarantine_slot_path(path: Path, key: bytes, slot: int) -> Path:
    if slot < 0 or slot >= MAX_RECOVERY_QUARANTINES:
        raise ValueError("invalid recovery quarantine slot")
    digest = hmac.new(
        key,
        b"firstmate/session-authority-quarantine/v1\0"
        + path.name.encode("utf-8")
        + b"\0"
        + str(slot).encode("ascii"),
        hashlib.sha256,
    ).hexdigest()
    return path.with_name(f".{path.name}.recovery-{digest}")


def write_quarantine_receipt(
    quarantine: Path, metadata: dict[str, str], proof: Path, key: bytes,
    quarantine_stat: os.stat_result | None = None
) -> None:
    if quarantine_stat is None:
        quarantine_stat = quarantine.lstat()
    body = (
        "version=1\n"
        f"name={quarantine.name}\n"
        f"proof={proof.name}\n"
        f"dev={quarantine_stat.st_dev}\n"
        f"ino={quarantine_stat.st_ino}\n"
        f"metadata={record_metadata_digest(metadata)}\n"
    ).encode("utf-8")
    body += (
        "hmac="
        + hmac.new(key, body, hashlib.sha256).hexdigest()
        + "\n"
    ).encode("ascii")
    temporary = quarantine.with_name(
        quarantine.name + QUARANTINE_RECEIPT_TEMP_SUFFIX
    )
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(body)
            output.flush()
            os.fsync(output.fileno())
        descriptor = -1
        rename_noreplace(
            temporary,
            quarantine.with_name(quarantine.name + QUARANTINE_RECEIPT_SUFFIX),
        )
    except BaseException:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def quarantine_receipt_fields(
    quarantine: Path, key: bytes
) -> dict[str, str] | None:
    receipt_path = quarantine.with_name(
        quarantine.name + QUARANTINE_RECEIPT_SUFFIX
    )
    try:
        receipt_stat = receipt_path.lstat()
        if (
            not stat.S_ISREG(receipt_stat.st_mode)
            or receipt_stat.st_size > MAX_QUARANTINE_RECEIPT_BYTES
        ):
            return None
        lines = receipt_path.read_bytes().splitlines(keepends=True)
        if len(lines) != 7 or any(not line.endswith(b"\n") for line in lines):
            return None
        fields: dict[str, str] = {}
        for line in lines:
            name, separator, value = line[:-1].partition(b"=")
            if not separator:
                return None
            name = name.decode("ascii")
            value = value.decode("ascii")
            if not name or name in fields:
                return None
            fields[name] = value
        if set(fields) != {
            "version", "name", "proof", "dev", "ino", "metadata", "hmac"
        }:
            return None
        if fields["version"] != "1" or fields["name"] != quarantine.name:
            return None
        proof = quarantine.with_name(quarantine.name + QUARANTINE_PROOF_SUFFIX)
        if fields["proof"] != proof.name:
            return None
        body = b"".join(lines[:6])
        expected_hmac = hmac.new(key, body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(fields["hmac"], expected_hmac):
            return None
        if int(fields["dev"]) < 0 or int(fields["ino"]) < 0:
            return None
        if len(fields["metadata"]) != 64 or any(
            value not in "0123456789abcdef" for value in fields["metadata"]
        ):
            return None
        return fields
    except (OSError, UnicodeError, ValueError):
        return None


def quarantine_receipt_matches(
    quarantine: Path, metadata: dict[str, str] | None, key: bytes
) -> bool:
    fields = quarantine_receipt_fields(quarantine, key)
    if fields is None:
        return False
    try:
        proof = quarantine.with_name(
            quarantine.name + QUARANTINE_PROOF_SUFFIX
        )
        if metadata is not None and fields["metadata"] != record_metadata_digest(metadata):
            return False
        try:
            proof_stat = proof.lstat()
        except FileNotFoundError:
            return metadata is None and not quarantine.exists()
        try:
            quarantine_stat = quarantine.lstat()
        except FileNotFoundError:
            quarantine_stat = None
        if quarantine_stat is not None and (
            fields["dev"] != str(quarantine_stat.st_dev)
            or fields["ino"] != str(quarantine_stat.st_ino)
            or proof_stat.st_dev != quarantine_stat.st_dev
            or proof_stat.st_ino != quarantine_stat.st_ino
        ):
            return False
        if quarantine_stat is None and (
            fields["dev"] != str(proof_stat.st_dev)
            or fields["ino"] != str(proof_stat.st_ino)
        ):
            return False
        return True
    except (OSError, UnicodeError, ValueError):
        return False


def cleanup_one_recovery_quarantine(
    path: Path, record: Path, expected: dict[str, str], key: bytes
) -> bool:
    identity = path.with_name(path.name + QUARANTINE_IDENTITY_SUFFIX)
    temporary = path.with_name(
        path.name + QUARANTINE_RECEIPT_TEMP_SUFFIX
    )
    proof = path.with_name(path.name + QUARANTINE_PROOF_SUFFIX)
    receipt = path.with_name(path.name + QUARANTINE_RECEIPT_SUFFIX)
    try:
        fields = quarantine_receipt_fields(path, key)
        authenticated = fields is not None
        if not path.exists() and not path.is_symlink():
            if authenticated:
                if not quarantine_receipt_matches(path, None, key):
                    return False
                try:
                    proof.unlink()
                except FileNotFoundError:
                    pass
                try:
                    receipt.unlink()
                except FileNotFoundError:
                    pass
                return True
            if proof.exists():
                proof.unlink()
            return True
        if path.is_symlink():
            return not authenticated
        if not authenticated and not proof.exists():
            return True
        os.link(path, identity, follow_symlinks=False)
        identity_stat = identity.lstat()
        current_stat = path.lstat()
        metadata = read_record_shape(path)
        if (
            identity_stat.st_dev != current_stat.st_dev
            or identity_stat.st_ino != current_stat.st_ino
            or any(metadata.get(name) != value for name, value in expected.items())
        ):
            return not authenticated
        if authenticated:
            if not proof.exists():
                os.link(path, proof, follow_symlinks=False)
            if not quarantine_receipt_matches(path, metadata, key):
                return False
        else:
            proof_stat = proof.lstat()
            if (
                proof_stat.st_dev != current_stat.st_dev
                or proof_stat.st_ino != current_stat.st_ino
            ):
                return True
            try:
                write_quarantine_receipt(
                    path, metadata, proof, key, quarantine_stat=current_stat
                )
            except (OSError, UnicodeError, ValueError):
                return True
        path.unlink()
        try:
            proof.unlink()
        except FileNotFoundError:
            pass
        try:
            receipt.unlink()
        except FileNotFoundError:
            pass
        return True
    except FileNotFoundError:
        if (
            not path.exists()
            and quarantine_receipt_fields(path, key) is not None
            and quarantine_receipt_matches(path, None, key)
        ):
            try:
                proof.unlink()
            except FileNotFoundError:
                pass
            try:
                receipt.unlink()
            except FileNotFoundError:
                pass
            return True
        return False
    except (OSError, UnicodeError, ValueError):
        return False
    finally:
        for artifact in (identity, temporary):
            try:
                artifact.unlink()
            except OSError:
                pass


def cleanup_recovery_quarantines(
    path: Path, expected: dict[str, str], key: bytes
) -> bool:
    quarantines = [
        quarantine_slot_path(path, key, slot)
        for slot in range(MAX_RECOVERY_QUARANTINES)
    ]
    for quarantine in quarantines:
        cleanup_one_recovery_quarantine(quarantine, path, expected, key)
    return not any(
        quarantine_receipt_fields(quarantine, key) is not None
        for quarantine in quarantines
    )


def unlink_owned_record(
    path: Path, expected: dict[str, str], expected_stat: os.stat_result | None = None,
    *, lock_held: bool = False, quarantine_key: bytes | None = None
) -> bool:
    def same_inode(left: os.stat_result, right: os.stat_result) -> bool:
        return left.st_dev == right.st_dev and left.st_ino == right.st_ino

    try:
        if not lock_held:
            with record_lock(
                path, blocking=False, expected_stat=expected_stat
            ) as lock:
                if lock is None:
                    return False
                return unlink_owned_record(
                    path,
                    expected,
                    expected_stat=expected_stat,
                    lock_held=True,
                    quarantine_key=quarantine_key,
                )
        if quarantine_key is None:
            return False
        initial_stat = path.lstat()
        if expected_stat is not None and (
            initial_stat.st_dev != expected_stat.st_dev
            or initial_stat.st_ino != expected_stat.st_ino
        ):
            return False
        metadata = read_record_shape(path)
        if any(metadata.get(key) != value for key, value in expected.items()):
            return False
        for slot in range(MAX_RECOVERY_QUARANTINES):
            quarantine = quarantine_slot_path(path, quarantine_key, slot)
            proof = quarantine.with_name(quarantine.name + QUARANTINE_PROOF_SUFFIX)
            receipt = quarantine.with_name(
                quarantine.name + QUARANTINE_RECEIPT_SUFFIX
            )
            proof_created = False
            receipt_created = False
            try:
                os.link(path, proof, follow_symlinks=False)
                proof_created = True
                try:
                    write_quarantine_receipt(
                        quarantine,
                        metadata,
                        proof,
                        quarantine_key,
                        quarantine_stat=initial_stat,
                    )
                    receipt_created = True
                except BaseException:
                    if proof_created:
                        try:
                            proof.unlink()
                        except OSError:
                            pass
                    raise
                rename_noreplace(path, quarantine)
            except FileExistsError:
                if receipt_created:
                    try:
                        receipt.unlink()
                    except OSError:
                        pass
                if proof_created:
                    try:
                        proof.unlink()
                    except OSError:
                        pass
                continue
            except FileNotFoundError:
                if receipt_created:
                    try:
                        receipt.unlink()
                    except OSError:
                        pass
                if proof_created:
                    try:
                        proof.unlink()
                    except OSError:
                        pass
                return False
            try:
                quarantined_stat = quarantine.lstat()
                quarantined_metadata = read_record_shape(quarantine)
                if same_inode(initial_stat, quarantined_stat) and all(
                    quarantined_metadata.get(key) == value
                    for key, value in expected.items()
                ) and quarantine_receipt_matches(
                    quarantine, quarantined_metadata, quarantine_key
                ):
                    return True
            except (OSError, UnicodeError, ValueError):
                pass
            try:
                rename_noreplace(quarantine, path)
            except FileExistsError:
                return False
            except OSError:
                return False
            try:
                proof.unlink()
            except FileNotFoundError:
                pass
            try:
                receipt.unlink()
            except FileNotFoundError:
                pass
            return False
        return False
    except (FileNotFoundError, OSError, UnicodeError, ValueError):
        return False


def broker_command_matches(
    command: list[str], *, script: str, state: str, home: str,
    checkout: str, task: str, launch_script: str
) -> bool:
    common = (
        len(command) >= 15
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
    )
    legacy = (
        len(command) == 15
        and command[11] == "--launch-evidence-fd"
        and command[12] == str(RECOVERY_LAUNCH_EVIDENCE_FD)
        and command[13] == "--launch-script"
        and canonical(command[14]) == launch_script
    )
    inherited = (
        len(command) == 17
        and command[11] == "--record-lock-fd"
        and command[12] == str(AUTHORITY_SERIALIZATION_FD)
        and command[13] == "--launch-evidence-fd"
        and command[14] == str(RECOVERY_LAUNCH_EVIDENCE_FD)
        and command[15] == "--launch-script"
        and canonical(command[16]) == launch_script
    )
    return common and command[10] == task and (legacy or inherited)


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
    record = Path(args.record)
    try:
        metadata = read_record_shape(record)
        raw_home = metadata.get("home", "")
        task = metadata.get("task", "")
        launch_script = metadata.get("launch-script", "")
        if not raw_home or not task or not launch_script:
            return 1
        expected_home = canonical(raw_home)
        args.task = task
        args.home = expected_home
        args.state = canonical(str(record.parent))
        args.checkout = canonical(metadata.get("checkout", ""))
        args.launch_script = canonical(launch_script)
        launch_evidence = read_launch_evidence(
            RECOVERY_LAUNCH_EVIDENCE_FD,
            home=expected_home,
            task=args.task,
            launch_script=args.launch_script,
        )
        return recover_stale_locked(args, launch_evidence=launch_evidence)
    except FileNotFoundError:
        return 0 if not record.exists() and not record.is_symlink() else 1
    except (OSError, UnicodeError, ValueError):
        return 1


def recover_stale_locked(
    args: argparse.Namespace,
    *, launch_evidence: tuple[bytes, int, str, str] | None = None,
    lease: socket.socket | None = None,
) -> int:
    if not sys.platform.startswith("linux") or not hasattr(socket, "SO_PEERCRED"):
        return 1
    record = Path(args.record)
    try:
        metadata = read_record_shape(record)
        requested_task = getattr(args, "task", metadata["task"])
        requested_home = canonical(getattr(args, "home", metadata["home"]))
        requested_state = canonical(getattr(args, "state", str(record.parent)))
        requested_checkout = canonical(
            getattr(args, "checkout", metadata["checkout"])
        )
        requested_launch_script = canonical(
            getattr(args, "launch_script", metadata["launch-script"])
        )
        expected_script = canonical(__file__)
        expected_checkout = canonical(str(Path(expected_script).parent.parent))
        if (
            metadata["task"] != requested_task
            or canonical(metadata["home"]) != requested_home
            or canonical(metadata["checkout"]) != requested_checkout
            or metadata["launch-script"] != requested_launch_script
            or canonical(str(record.parent)) != requested_state
            or requested_checkout != expected_checkout
            or requested_launch_script
            != canonical(f"{requested_home}/bin/fm-session-authority-exec.sh")
        ):
            return 1
        if launch_evidence is None:
            launch_evidence = read_launch_evidence(
                RECOVERY_LAUNCH_EVIDENCE_FD,
                home=requested_home,
                task=requested_task,
                launch_script=requested_launch_script,
            )
        def recover_under_lease(lock: AuthorityRecordLock | None) -> int:
            if lock is None:
                return 1
            record_stat = record.lstat()
            metadata = read_record_shape(record)
            if launch_evidence is None:
                return 1
            _, launch_pid, _, _ = launch_evidence
            if (
                metadata["task"] != requested_task
                or canonical(metadata["home"]) != requested_home
                or canonical(metadata["checkout"]) != requested_checkout
                or metadata["checkout"] != expected_checkout
                or metadata["script"] != expected_script
                or metadata["launch-script"] != requested_launch_script
                or canonical(str(record.parent)) != requested_state
                or requested_launch_script
                != canonical(f"{requested_home}/bin/fm-session-authority-exec.sh")
                or requested_task == ""
                or requested_home == ""
                or requested_state == ""
                or requested_checkout == ""
                or requested_launch_script == ""
                or requested_launch_script != canonical(
                    f"{requested_home}/bin/fm-session-authority-exec.sh"
                )
            ):
                return 1
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
                state=requested_state,
                home=requested_home,
                checkout=requested_checkout,
                task=requested_task,
                launch_script=requested_launch_script,
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
                    quarantine_key=derive_broker_durable_key(
                        launch_evidence[0],
                        task=requested_task,
                        home=requested_home,
                        launch_pid=launch_evidence[1],
                        launch_start=launch_evidence[2],
                        launch_identity=launch_evidence[3],
                        launch_script=requested_launch_script,
                    ),
                )
            )
        if lease is not None:
            return recover_under_lease(lease)
        with record_lock(
            record,
            blocking=False,
            authority_home=requested_home,
            authority_task=requested_task,
            launch_script=requested_launch_script,
            launch_evidence=launch_evidence,
        ) as lock:
            return recover_under_lease(lock)
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
    server.add_argument("--record-lock-fd", type=int, default=-1)
    supervisor = subparsers.add_parser("supervise", add_help=False)
    supervisor.add_argument("--state", required=True)
    supervisor.add_argument("--home", required=True)
    supervisor.add_argument("--checkout", required=True)
    supervisor.add_argument("--task", required=True)
    supervisor.add_argument("--launch-evidence-fd", type=int, required=True)
    supervisor.add_argument("--launch-script", required=True)
    recovery = subparsers.add_parser("recover-stale", add_help=False)
    recovery.add_argument("--record", required=True)
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    if arguments.mode == "serve":
        result = serve(arguments)
    elif arguments.mode == "supervise":
        result = supervise(arguments)
    elif arguments.mode == "client":
        result = client(arguments)
    else:
        result = recover_stale(arguments)
    raise SystemExit(result)
