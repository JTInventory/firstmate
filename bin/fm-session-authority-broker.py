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
import threading
import time


MAX_BODY = 1024 * 1024
PROTOCOL_VERSION = 1
MAX_ANCESTRY_DEPTH = 128
BROKER_REQUEST_TIMEOUT_SECONDS = 2.0
RECOVERY_LAUNCH_EVIDENCE_FD = 19
AUTHORITY_SERIALIZATION_FD = 18
ADMISSION_CAPABILITY_FD = 21
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


def descriptor_identity(pid: int, fd: int) -> str:
    target = os.readlink(f"/proc/{pid}/fd/{fd}")
    if not target:
        raise ValueError("empty authority descriptor")
    return target


def anonymous_pipe_identity(fd: int) -> str:
    target = descriptor_identity(os.getpid(), fd)
    if not (
        target.startswith("pipe:[")
        and target.endswith("]")
        and target[6:-1].isdigit()
    ):
        raise ValueError("inherited capability is nameable")
    return target


def process_runs_script(pid: int, script: str) -> bool:
    command = process_command(pid)
    return len(command) >= 2 and canonical(command[1]) == canonical(script)


def process_ancestry_contains(pid: int, wanted: int) -> bool:
    current = pid
    visited: set[int] = set()
    for _ in range(MAX_ANCESTRY_DEPTH):
        if current == wanted:
            return True
        if current <= 1 or current in visited:
            return False
        visited.add(current)
        parent = parent_pid(current)
        if parent == current or parent < 1:
            return False
        current = parent
    return False


def trusted_wrapper_ancestor(
    pid: int, home: str, launch_script: str, capability_fd: int = -1
) -> bool:
    descriptor = None
    if capability_fd >= 0:
        descriptor = descriptor_identity(pid, capability_fd)
    current = pid
    visited: set[int] = set()
    for _ in range(MAX_ANCESTRY_DEPTH):
        try:
            if (
                process_runs_script(current, launch_script)
                and canonical(os.readlink(f"/proc/{current}/cwd")) == home
                and (
                    capability_fd < 0
                    or descriptor_identity(current, capability_fd) == descriptor
                )
            ):
                process_generation(current)
                return True
            if current <= 1 or current in visited:
                return False
            visited.add(current)
            parent = parent_pid(current)
            if parent == current or parent < 1:
                return False
            current = parent
        except (OSError, UnicodeError, ValueError):
            return False
    return False


def trusted_admission_ancestor(pid: int, home: str, launch_script: str) -> bool:
    descriptor = descriptor_identity(pid, AUTHORITY_SERIALIZATION_FD)
    current = pid
    visited: set[int] = set()
    lock_script = f"{home}/bin/fm-lock.sh"
    for _ in range(MAX_ANCESTRY_DEPTH):
        try:
            if (
                (
                    process_runs_script(current, launch_script)
                    or process_runs_script(current, lock_script)
                )
                and canonical(os.readlink(f"/proc/{current}/cwd")) == home
                and descriptor_identity(current, AUTHORITY_SERIALIZATION_FD)
                == descriptor
            ):
                process_generation(current)
                return True
            if current <= 1 or current in visited:
                return False
            visited.add(current)
            parent = parent_pid(current)
            if parent == current or parent < 1:
                return False
            current = parent
        except (OSError, UnicodeError, ValueError):
            return False
    return False


ADMISSION_REQUEST_PREFIX = b"firstmate/session-authority/admission/v1\0"
ADMISSION_CHALLENGE_PREFIX = (
    b"firstmate/session-authority/admission/challenge/v1\0"
)


def read_process_fd_line(pid: int, fd: int) -> str:
    with open(f"/proc/{pid}/fd/{fd}", "rb", buffering=0) as source:
        value = source.readline()
    key = value.decode("ascii").strip()
    if len(key) < 64 or len(key) % 2 or any(c not in "0123456789abcdef" for c in key):
        raise ValueError("malformed primary authority key")
    return key


def read_inherited_capability(fd: int) -> str:
    if fd < 3 or not stat.S_ISFIFO(os.fstat(fd).st_mode):
        raise ValueError("inherited capability is not an anonymous pipe")
    identity = anonymous_pipe_identity(fd)
    descriptor = os.dup(fd)
    try:
        if anonymous_pipe_identity(descriptor) != identity:
            raise ValueError("inherited capability descriptor changed")
        os.set_blocking(descriptor, False)
        chunks: list[bytes] = []
        deadline = time.monotonic() + AUTHORITY_LOCK_TIMEOUT_SECONDS
        while True:
            try:
                chunk = os.read(descriptor, 4096)
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("inherited capability unavailable")
                time.sleep(0.01)
                continue
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk or sum(len(value) for value in chunks) > 4096:
                break
        value = b"".join(chunks).split(b"\n", 1)[0]
    finally:
        os.close(descriptor)
    key = value.decode("ascii")
    if len(key) < 64 or len(key) % 2 or any(
        c not in "0123456789abcdef" for c in key
    ):
        raise ValueError("malformed inherited capability")
    return key


def authority_hmac(key: str, body: bytes) -> str:
    key_bytes = bytes.fromhex(key)[:64]
    key_bytes = key_bytes.ljust(64, b"\0")
    inner = hashlib.sha256(
        bytes(value ^ 0x36 for value in key_bytes) + body
    ).digest()
    return hashlib.sha256(
        bytes(value ^ 0x5C for value in key_bytes) + inner
    ).hexdigest()


def read_primary_authority(path: Path) -> dict[str, str]:
    file_stat = path.lstat()
    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_mode & 0o077:
        raise ValueError("unsafe primary authority")
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    ordered = ("version", "pid", "start", "identity", "token", "owner", "home", "checkout")
    if len(lines) != len(ordered) or any(not line.endswith("\n") for line in lines):
        raise ValueError("malformed primary authority")
    fields: dict[str, str] = {}
    for expected, line in zip(ordered, lines):
        prefix = f"{expected}="
        if not line.startswith(prefix) or line.count("=") != 1:
            raise ValueError("malformed primary authority")
        value = line[len(prefix):-1]
        if not value or "\x00" in value or "\r" in value:
            raise ValueError("malformed primary authority")
        fields[expected] = value
    if fields["version"] != "2" or len(fields["token"]) != 64:
        raise ValueError("malformed primary authority")
    if any(c not in "0123456789abcdef" for c in fields["token"]):
        raise ValueError("malformed primary authority")
    try:
        if int(fields["pid"]) <= 1:
            raise ValueError
    except ValueError as error:
        raise ValueError("malformed primary authority") from error
    return fields


def read_primary_root(path: Path) -> dict[str, str]:
    file_stat = path.lstat()
    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_mode & 0o077:
        raise ValueError("unsafe primary root")
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    ordered = (
        "version", "task", "home", "primary-home", "primary-checkout",
        "authority-pid", "authority-start", "authority-identity",
        "authority-fd", "authority-descriptor", "durable-descriptor",
        "authority-sha256", "authority-hmac",
    )
    if len(lines) != len(ordered) or any(not line.endswith("\n") for line in lines):
        raise ValueError("malformed primary root")
    fields: dict[str, str] = {}
    for expected, line in zip(ordered, lines):
        prefix = f"{expected}="
        if not line.startswith(prefix) or line.count("=") != 1:
            raise ValueError("malformed primary root")
        value = line[len(prefix):-1]
        if not value or "\x00" in value or "\r" in value:
            raise ValueError("malformed primary root")
        fields[expected] = value
    if (
        fields["version"] != "1"
        or len(fields["authority-hmac"]) != 64
        or len(fields["authority-sha256"]) != 64
    ):
        raise ValueError("malformed primary root")
    if any(
        c not in "0123456789abcdef"
        for c in fields["authority-hmac"] + fields["authority-sha256"]
    ):
        raise ValueError("malformed primary root")
    try:
        if int(fields["authority-pid"]) <= 1 or int(fields["authority-fd"]) < 3:
            raise ValueError
    except ValueError as error:
        raise ValueError("malformed primary root") from error
    return fields


def verify_trusted_primary_authority(
    ticket_fields: dict[str, str], *, home: str, launch_pid: int,
    launch_start: str, launch_identity: str
) -> None:
    primary_root = Path(home) / "state" / ".session-primary-root"
    root_state = primary_root.parent
    if root_state.is_symlink() or not root_state.is_dir():
        raise ValueError("untrusted primary root")
    root_fields = read_primary_root(primary_root)
    root_body = primary_root.read_bytes().splitlines(keepends=True)
    durable_descriptor = root_fields["durable-descriptor"]
    issuer_value = root_fields["primary-home"]
    issuer = Path(issuer_value)
    if (
        not issuer.is_absolute()
        or issuer.is_symlink()
        or not issuer.is_dir()
        or canonical(issuer_value) != issuer_value
        or issuer_value == home
        or (issuer / ".fm-secondmate-home").exists()
    ):
        raise ValueError("untrusted primary home")
    if (
        root_fields["task"] != ticket_fields["task"]
        or root_fields["home"] != home
        or ticket_fields["issuer-home"] != issuer_value
        or ticket_fields["primary-root-sha256"]
        != hashlib.sha256(primary_root.read_bytes()).hexdigest()
    ):
        raise ValueError("untrusted primary root binding")
    state = issuer / "state"
    lock = state / ".lock"
    binding = state / ".primary-checkout"
    authority = state / ".session-authority"
    if any(path.is_symlink() for path in (state, lock, binding, authority)):
        raise ValueError("untrusted primary authority")
    if not state.is_dir() or not lock.is_file() or not binding.is_file():
        raise ValueError("untrusted primary authority")
    authority_fields = read_primary_authority(authority)
    broker_script = str(
        Path(root_fields["primary-checkout"])
        / "bin"
        / "fm-session-authority-exec.sh"
    )
    if (
        not os.path.isabs(root_fields["primary-checkout"])
        or canonical(root_fields["primary-checkout"]) != root_fields["primary-checkout"]
        or canonical(broker_script) != broker_script
        or Path(broker_script).name != "fm-session-authority-exec.sh"
        or Path(broker_script).parent.name != "bin"
        or not Path(broker_script).is_file()
        or Path(broker_script).is_symlink()
    ):
        raise ValueError("untrusted primary authority script")
    checkout = canonical(str(Path(broker_script).parent.parent))
    owner = authority_fields["owner"]
    if (
        authority_fields["home"] != issuer_value
        or canonical(authority_fields["checkout"]) != checkout
        or root_fields["primary-checkout"] != checkout
        or root_fields["authority-sha256"]
        != hashlib.sha256(authority.read_bytes()).hexdigest()
        or lock.read_text(encoding="utf-8") != owner + "\n"
        or binding.read_text(encoding="utf-8") != checkout + "\n"
        or ticket_fields["broker-script"] != broker_script
        or ticket_fields["issuer-authority"] != root_fields["authority-sha256"]
    ):
        raise ValueError("untrusted primary authority binding")
    try:
        authority_pid = int(authority_fields["pid"])
        authority_fd = int(root_fields["authority-fd"])
    except ValueError as error:
        raise ValueError("malformed primary authority identity") from error
    if authority_fd < 3 or authority_pid != int(root_fields["authority-pid"]):
        raise ValueError("untrusted primary authority identity")
    key = read_process_fd_line(authority_pid, 18)
    if not hmac.compare_digest(
        root_fields["authority-hmac"],
        authority_hmac(key, b"".join(root_body[:-1])),
    ):
        raise ValueError("untrusted primary root authentication")
    if (
        process_generation(authority_pid)
        != (authority_fields["start"], authority_fields["identity"])
        or (authority_fields["start"], authority_fields["identity"])
        != (root_fields["authority-start"], root_fields["authority-identity"])
        or descriptor_identity(authority_pid, 18)
        != root_fields["durable-descriptor"]
        or (ticket_fields["broker-pid"], ticket_fields["broker-start"],
            ticket_fields["broker-identity"])
        != (str(authority_pid), root_fields["authority-start"],
            root_fields["authority-identity"])
        or ticket_fields["authority-fd"] != root_fields["authority-fd"]
        or ticket_fields["authority-descriptor"]
        != descriptor_identity(authority_pid, authority_fd)
        or not process_runs_script(authority_pid, broker_script)
        or canonical(os.readlink(f"/proc/{authority_pid}/cwd")) != issuer_value
    ):
        raise ValueError("untrusted primary authority process")
    authority_environment = process_environment(authority_pid)
    if (
        authority_environment.get("FM_AGENT_ROLE", "") not in ("", "primary")
        or authority_environment.get("FM_AGENT_TASK")
        or authority_environment.get("FM_AGENT_OWNER_HOME")
        or (
            authority_environment.get("FM_HOME")
            and canonical(authority_environment["FM_HOME"]) != issuer_value
        )
        or (
            authority_environment.get("FM_ROOT_OVERRIDE")
            and canonical(authority_environment["FM_ROOT_OVERRIDE"]) != checkout
        )
    ):
        raise ValueError("untrusted primary authority provenance")
    authority_body = "".join(
        f"{authority_fields[field]}\n"
        for field in ("pid", "start", "identity", "owner", "home", "checkout")
    ).encode("utf-8")
    if not hmac.compare_digest(
        authority_fields["token"], authority_hmac(key, authority_body)
    ):
        raise ValueError("untrusted primary authority token")
    signer_pid = int(ticket_fields["signer-pid"])
    signer_script = str(Path(checkout) / "bin" / "fm-session-enrollment-signer.sh")
    if (
        process_generation(signer_pid)
        != (ticket_fields["signer-start"], ticket_fields["signer-identity"])
        or not process_runs_script(signer_pid, signer_script)
        or descriptor_identity(signer_pid, authority_fd)
        != ticket_fields["authority-descriptor"]
        or descriptor_identity(signer_pid, 18) != durable_descriptor
        or not process_ancestry_contains(signer_pid, authority_pid)
    ):
        raise ValueError("untrusted primary signer")
    if launch_pid <= 1 or launch_pid == authority_pid:
        raise ValueError("untrusted enrollment endpoint")


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
        if len(command) < 3 or canonical(command[1]) != script or command[2] not in {
            "client", "lock-holder"
        }:
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
        if command[2] == "lock-holder":
            if (
                len(command) != 7
                or command[3] != "--record"
                or command[5] != "--capability-fd"
                or command[6] != str(ADMISSION_CAPABILITY_FD)
            ):
                return False
            if not trusted_wrapper_ancestor(
                pid, home, f"{home}/bin/fm-session-authority-exec.sh",
                ADMISSION_CAPABILITY_FD
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
            "endpoint-pid", "endpoint-start", "endpoint-identity",
            "primary-root-sha256", "signature",
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
        or ticket_fields["nonce"] != fields["nonce"]
        or ticket_fields["endpoint-pid"] != str(launch_pid)
        or ticket_fields["endpoint-start"] != fields["start"]
        or ticket_fields["endpoint-identity"] != fields["identity"]
        or len(ticket_fields["primary-root-sha256"]) != 64
        or any(c not in "0123456789abcdef" for c in ticket_fields["primary-root-sha256"])
        or ticket_fields["public-key-sha256"]
        != hashlib.sha256(
            base64.b64decode(ticket_fields["public-key"], validate=True)
        ).hexdigest()
        or not verify_embedded_signature(
            ticket_fields["public-key"], ticket_fields["signature"],
            b"".join(ticket_lines[:22]),
        )
    ):
        raise ValueError("untrusted enrollment ticket")
    verify_trusted_primary_authority(
        ticket_fields,
        home=home,
        launch_pid=launch_pid,
        launch_start=fields["start"],
        launch_identity=fields["identity"],
    )
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
    capability_fd: int = -1,
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
            capability_fd=capability_fd,
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


def open_inherited_authority_record_lock(
    fd: int, *, blocking: bool
) -> AuthorityRecordLock | None:
    if fd < 3:
        return None
    deadline = time.monotonic() + AUTHORITY_LOCK_TIMEOUT_SECONDS
    while True:
        try:
            lock_stat = os.fstat(fd)
            if not stat.S_ISFIFO(lock_stat.st_mode):
                return None
            read_inherited_capability(fd)
            os.set_inheritable(fd, True)
            return AuthorityRecordLock(fd)
        except (OSError, UnicodeError, ValueError):
            if not blocking or time.monotonic() >= deadline:
                return None
            time.sleep(0.01)


def open_authority_record_lock(
    *, blocking: bool, state: Path | None = None, home: str | None = None,
    task: str | None = None,
    launch_script: str | None = None,
    launch_evidence: tuple[bytes, int, str, str] | None = None,
    capability_fd: int = -1,
) -> AuthorityRecordLock | None:
    if (
        state is None or home is None or task is None or launch_script is None
        or launch_evidence is None or capability_fd < 3
    ):
        return None
    if not state.is_dir() or state.is_symlink() or canonical(str(state.parent)) != home:
        return None
    if not task or canonical(launch_script) != canonical(
        f"{home}/bin/fm-session-authority-exec.sh"
    ):
        return None
    return open_inherited_authority_record_lock(capability_fd, blocking=blocking)


def inherited_authority_record_lock(
    fd: int, *, home: str, task: str,
    launch_script: str,
    launch_evidence: tuple[bytes, int, str, str]
) -> AuthorityRecordLock | None:
    if fd != AUTHORITY_SERIALIZATION_FD or not task or canonical(
        launch_script
    ) != canonical(f"{home}/bin/fm-session-authority-exec.sh"):
        return None
    return open_inherited_authority_record_lock(fd, blocking=False)


def move_authority_record_lock(
    lock: AuthorityRecordLock, target_fd: int
) -> AuthorityRecordLock:
    if lock.fileno() == target_fd:
        os.set_inheritable(target_fd, True)
        return lock
    source_fd = lock.fileno()
    os.dup2(source_fd, target_fd)
    os.close(source_fd)
    return AuthorityRecordLock(target_fd)


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
        record_lock_fd = move_authority_record_lock(
            record_lock_fd, AUTHORITY_SERIALIZATION_FD
        )
    except OSError:
        close_record_lock(record_lock_fd)
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
            written = os.write(write_fd, data[offset:])
            if written <= 0:
                raise OSError("short launch evidence write")
            offset += written
        os.dup2(read_fd, RECOVERY_LAUNCH_EVIDENCE_FD, inheritable=True)
    finally:
        os.close(write_fd)
        if read_fd != RECOVERY_LAUNCH_EVIDENCE_FD:
            os.close(read_fd)


def install_capability_bytes(data: bytes) -> None:
    read_fd, write_fd = os.pipe()
    try:
        offset = 0
        while offset < len(data):
            written = os.write(write_fd, data[offset:])
            if written <= 0:
                raise OSError("short capability write")
            offset += written
        os.dup2(read_fd, AUTHORITY_SERIALIZATION_FD, inheritable=True)
    finally:
        os.close(write_fd)
        if read_fd != AUTHORITY_SERIALIZATION_FD:
            os.close(read_fd)


def write_supervisor_barrier_signal(fd: int, value: bytes) -> None:
    offset = 0
    while offset < len(value):
        written = os.write(fd, value[offset:])
        if written <= 0:
            raise OSError("short supervisor barrier signal")
        offset += written


def supervise(args: argparse.Namespace) -> int:
    record_lock_fd: AuthorityRecordLock | None = None
    barrier_ready_fd = getattr(args, "barrier_ready_fd", -1)
    barrier_release_fd = getattr(args, "barrier_release_fd", -1)
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
        record_lock_argument = getattr(args, "record_lock_fd", -1)
        if (
            record_lock_argument < 3
            or record_lock_argument == AUTHORITY_SERIALIZATION_FD
        ):
            return 1
        capability = read_inherited_capability(record_lock_argument)
        if not trusted_admission_ancestor(
            os.getpid(), home, launch_script
        ):
            return 1
        install_capability_bytes((capability + "\n").encode("ascii"))
        os.close(record_lock_argument)
        record_lock_fd = AuthorityRecordLock(AUTHORITY_SERIALIZATION_FD)
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
        if barrier_ready_fd >= 3:
            write_supervisor_barrier_signal(
                barrier_ready_fd, f"READY pid={os.getpid()}\n".encode("ascii")
            )
            os.close(barrier_ready_fd)
            barrier_ready_fd = -1
        if barrier_release_fd >= 3:
            release = os.read(barrier_release_fd, len(b"GO\n"))
            if release != b"GO\n":
                return 1
            os.close(barrier_release_fd)
            barrier_release_fd = -1
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
        for descriptor in (barrier_ready_fd, barrier_release_fd):
            if descriptor >= 3:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
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
    active_lease: dict[str, object] | None = None
    lease_guard = threading.Lock()

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
        def release_lease_control(
            connection: socket.socket, lease_info: dict[str, object]
        ) -> None:
            nonlocal active_lease
            try:
                connection.settimeout(1.0)
                command = b""
                while not stopping:
                    try:
                        chunk = connection.recv(len(b"RELEASE\n") - len(command))
                    except socket.timeout:
                        if launch_process_state(
                            launch_pid, launch_start, launch_identity, launch_script
                        ) == "dead":
                            break
                        continue
                    if not chunk:
                        break
                    command += chunk
                    if len(command) >= len(b"RELEASE\n"):
                        break
                if command != b"RELEASE\n":
                    return
            except OSError:
                return
            finally:
                connection.close()
                with lease_guard:
                    if active_lease is lease_info:
                        active_lease = None

        while not stopping:
            if not record.is_file() or record.is_symlink() or not Path(home).is_dir():
                break
            if launch_process_state(
                launch_pid, launch_start, launch_identity, launch_script
            ) == "dead":
                break
            with lease_guard:
                if active_lease is not None and not bool(active_lease["control"]):
                    try:
                        lease_generation = process_generation(int(active_lease["pid"]))
                    except (OSError, UnicodeError, ValueError):
                        lease_generation = None
                    if (
                        time.monotonic() - float(active_lease["created"])
                        > BROKER_REQUEST_TIMEOUT_SECONDS
                        or lease_generation != active_lease["generation"]
                    ):
                        active_lease = None
            try:
                connection, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                if stopping:
                    break
                raise
            keep_connection = False
            try:
                request_deadline = time.monotonic() + BROKER_REQUEST_TIMEOUT_SECONDS
                credentials = connection.getsockopt(
                    socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
                )
                pid, uid, gid = struct.unpack("3i", credentials)
                header = recv_exact(connection, 5, request_deadline)
                kind, length = struct.unpack("!cI", header)
                if length > MAX_BODY or kind not in (b"L", b"D", b"K", b"R"):
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
                if kind == b"K":
                    if not body.startswith(ADMISSION_REQUEST_PREFIX):
                        raise ValueError("invalid admission request")
                    capability = body[len(ADMISSION_REQUEST_PREFIX):]
                    if (
                        len(capability) < 64
                        or len(capability) % 2
                        or any(
                            value not in b"0123456789abcdef"
                            for value in capability
                        )
                    ):
                        raise ValueError("invalid admission capability")
                    challenge = secrets.token_hex(32).encode("ascii")
                    connection.sendall(b"C" + challenge)
                    proof_header = recv_exact(connection, 5, request_deadline)
                    proof_kind, proof_length = struct.unpack("!cI", proof_header)
                    if proof_kind != b"K" or proof_length > MAX_BODY:
                        raise ValueError("invalid admission proof")
                    proof_body = recv_exact(
                        connection, proof_length, request_deadline
                    )
                    expected_proof = hmac.new(
                        bytes.fromhex(capability),
                        ADMISSION_CHALLENGE_PREFIX + challenge,
                        hashlib.sha256,
                    ).hexdigest().encode("ascii")
                    expected_body = (
                        ADMISSION_REQUEST_PREFIX + capability + b"\0"
                        + challenge + b"\0" + expected_proof
                    )
                    if not hmac.compare_digest(proof_body, expected_body):
                        raise ValueError("invalid admission proof")
                    with lease_guard:
                        if active_lease is not None:
                            connection.sendall(b"E")
                            continue
                        generation = process_generation(pid)
                        digest = hmac.new(
                            durable_key, body, hashlib.sha256
                        ).hexdigest().encode()
                        active_lease = {
                            "control": False,
                            "created": time.monotonic(),
                            "digest": digest,
                            "generation": generation,
                            "nonce": capability,
                            "pid": pid,
                        }
                    connection.sendall(b"O" + digest)
                    continue
                if kind == b"R":
                    with lease_guard:
                        lease_info = active_lease
                        if (
                            lease_info is None
                            or bool(lease_info["control"])
                            or int(lease_info["pid"]) != pid
                            or process_generation(pid) != lease_info["generation"]
                            or body
                            != b"firstmate/session-authority/admission/release/v1\0"
                            + bytes(lease_info["nonce"])
                            + b"\0"
                            + bytes(lease_info["digest"])
                        ):
                            connection.sendall(b"E")
                            continue
                        lease_info["control"] = True
                        connection.sendall(b"O" + bytes(lease_info["digest"]))
                        threading.Thread(
                            target=release_lease_control,
                            args=(connection, lease_info),
                            daemon=True,
                        ).start()
                        keep_connection = True
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
                if not keep_connection:
                    connection.close()
    finally:
        with lease_guard:
            if active_lease is not None:
                active_lease = None
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
        if getattr(args, "record_lock_fd", -1) != AUTHORITY_SERIALIZATION_FD:
            return 1
        launch_evidence = read_launch_evidence(
            RECOVERY_LAUNCH_EVIDENCE_FD,
            home=expected_home,
            task=args.task,
            launch_script=args.launch_script,
        )
        if not trusted_admission_ancestor(
            os.getpid(), expected_home, args.launch_script
        ):
            return 1
        return recover_stale_locked(args, launch_evidence=launch_evidence)
    except FileNotFoundError:
        return 0 if not record.exists() and not record.is_symlink() else 1
    except (OSError, UnicodeError, ValueError):
        return 1


def recover_stale_locked(
    args: argparse.Namespace,
    *, launch_evidence: tuple[bytes, int, str, str] | None = None,
    lease: AuthorityRecordLock | None = None,
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
            capability_fd=getattr(args, "record_lock_fd", -1),
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


def lock_holder(args: argparse.Namespace) -> int:
    connection: socket.socket | None = None
    control: socket.socket | None = None
    try:
        metadata = read_record(Path(args.record))
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(BROKER_REQUEST_TIMEOUT_SECONDS)
        socket_value = metadata["socket"]
        connection.connect(
            f"\0{socket_value.removeprefix('abstract:')}"
            if socket_value.startswith("abstract:")
            else socket_value
        )
        if not connected_peer_matches_record(connection, metadata):
            return 1
        nonce = read_inherited_capability(args.capability_fd)
        body = b"firstmate/session-authority/admission/v1\0" + nonce.encode()
        deadline = time.monotonic() + BROKER_REQUEST_TIMEOUT_SECONDS
        connection.sendall(struct.pack("!cI", b"K", len(body)) + body)
        challenge_response = recv_exact(connection, 65, deadline)
        if challenge_response[:1] != b"C" or any(
            value not in b"0123456789abcdef"
            for value in challenge_response[1:]
        ):
            return 1
        challenge = challenge_response[1:]
        proof = hmac.new(
            bytes.fromhex(nonce),
            ADMISSION_CHALLENGE_PREFIX + challenge,
            hashlib.sha256,
        ).hexdigest().encode("ascii")
        proof_body = body + b"\0" + challenge + b"\0" + proof
        connection.sendall(struct.pack("!cI", b"K", len(proof_body)) + proof_body)
        response = recv_exact(connection, 65, deadline)
        if response[:1] != b"O" or any(
            value not in b"0123456789abcdef" for value in response[1:]
        ):
            return 1
        connection.close()
        connection = None
        release_body = (
            b"firstmate/session-authority/admission/release/v1\0"
            + nonce.encode()
            + b"\0"
            + response[1:]
        )
        control = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        control.settimeout(BROKER_REQUEST_TIMEOUT_SECONDS)
        control.connect(
            f"\0{socket_value.removeprefix('abstract:')}"
            if socket_value.startswith("abstract:")
            else socket_value
        )
        if not connected_peer_matches_record(control, metadata):
            return 1
        control.sendall(struct.pack("!cI", b"R", len(release_body)) + release_body)
        control_response = recv_exact(
            control, 65, time.monotonic() + BROKER_REQUEST_TIMEOUT_SECONDS
        )
        if control_response[:1] != b"O" or any(
            value not in b"0123456789abcdef" for value in control_response[1:]
        ):
            return 1
        print("LOCKED", flush=True)
        print(f"PID {os.getpid()}", flush=True)
        command = sys.stdin.buffer.readline()
        if command != b"RELEASE\n":
            return 1
        control.settimeout(BROKER_REQUEST_TIMEOUT_SECONDS)
        control.sendall(b"RELEASE\n")
        control.close()
        control = None
        return 0
    except (OSError, UnicodeError, ValueError):
        return 1
    finally:
        if connection is not None:
            connection.close()
        if control is not None:
            control.close()


def primary_lock_holder(args: argparse.Namespace) -> int:
    lock: AuthorityRecordLock | None = None
    try:
        if (
            args.root_fd != AUTHORITY_SERIALIZATION_FD
            or args.capability_fd != ADMISSION_CAPABILITY_FD
        ):
            return 1
        state = Path(canonical(args.state))
        home = canonical(args.home)
        if (
            state.name != "state"
            or canonical(str(state.parent)) != home
            or not state.is_dir()
            or state.is_symlink()
            or canonical(args.launch_script)
            != canonical(f"{home}/bin/fm-session-authority-exec.sh")
        ):
            return 1
        caller = int(args.caller_pid)
        caller_generation = process_generation(caller)
        if caller_generation != (args.caller_start, args.caller_identity):
            return 1
        if not (
            process_runs_script(caller, canonical(args.launch_script))
            or process_runs_script(caller, f"{home}/bin/fm-lock.sh")
        ):
            return 1
        if canonical(os.readlink(f"/proc/{caller}/cwd")) != home:
            return 1
        if not trusted_wrapper_ancestor(
            caller, home, canonical(args.launch_script), args.capability_fd
        ):
            return 1
        capability_descriptor = descriptor_identity(
            os.getpid(), args.capability_fd
        )
        if descriptor_identity(caller, args.capability_fd) != capability_descriptor:
            return 1
        root_descriptor = descriptor_identity(os.getpid(), args.root_fd)
        if descriptor_identity(caller, args.root_fd) != root_descriptor:
            return 1
        lock = open_inherited_authority_record_lock(
            args.capability_fd, blocking=True
        )
        if lock is None:
            return 1
        print("LOCKED", flush=True)
        print(f"PID {os.getpid()}", flush=True)
        if sys.stdin.buffer.readline() != b"RELEASE\n":
            return 1
        return 0
    except (OSError, UnicodeError, ValueError):
        return 1
    finally:
        if lock is not None:
            close_record_lock(lock)


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
    holder = subparsers.add_parser("lock-holder", add_help=False)
    holder.add_argument("--record", required=True)
    holder.add_argument("--capability-fd", type=int, required=True)
    primary_holder = subparsers.add_parser("primary-lock-holder", add_help=False)
    primary_holder.add_argument("--state", required=True)
    primary_holder.add_argument("--home", required=True)
    primary_holder.add_argument("--launch-script", required=True)
    primary_holder.add_argument("--root-fd", type=int, required=True)
    primary_holder.add_argument("--capability-fd", type=int, required=True)
    primary_holder.add_argument("--caller-pid", required=True)
    primary_holder.add_argument("--caller-start", required=True)
    primary_holder.add_argument("--caller-identity", required=True)
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
    supervisor.add_argument("--record-lock-fd", type=int, required=True)
    supervisor.add_argument("--barrier-ready-fd", type=int, default=-1)
    supervisor.add_argument("--barrier-release-fd", type=int, default=-1)
    recovery = subparsers.add_parser("recover-stale", add_help=False)
    recovery.add_argument("--record", required=True)
    recovery.add_argument("--record-lock-fd", type=int, required=True)
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    if arguments.mode == "serve":
        result = serve(arguments)
    elif arguments.mode == "supervise":
        result = supervise(arguments)
    elif arguments.mode == "client":
        result = client(arguments)
    elif arguments.mode == "lock-holder":
        result = lock_holder(arguments)
    elif arguments.mode == "primary-lock-holder":
        result = primary_lock_holder(arguments)
    else:
        result = recover_stale(arguments)
    raise SystemExit(result)
