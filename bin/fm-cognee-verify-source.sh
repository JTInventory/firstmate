#!/usr/bin/env bash
# Parse Cognee hint text and verify references against a local manifest.
#
# This is intentionally local-only: it reads a saved answer fixture and a JSONL
# manifest, reopens the referenced local source file, and never calls Cognee.
# Usage: fm-cognee-verify-source.sh --manifest <manifest.jsonl> --answer <answer.txt>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-cognee-telemetry-lib.sh"
export FM_COGNEE_TELEMETRY_FILE="${FM_COGNEE_TELEMETRY_FILE:-$(fm_cognee_telemetry_default_path)}"
export FM_COGNEE_TELEMETRY_START_MS="$(fm_cognee_telemetry_now_ms)"

usage() {
  echo "usage: fm-cognee-verify-source.sh --manifest <manifest.jsonl> --answer <answer.txt>" >&2
}

MANIFEST=
ANSWER=
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      [ $# -ge 2 ] || { usage; exit 64; }
      MANIFEST=$2
      shift 2
      ;;
    --answer)
      [ $# -ge 2 ] || { usage; exit 64; }
      ANSWER=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

[ -n "$MANIFEST" ] || { usage; exit 64; }
[ -n "$ANSWER" ] || { usage; exit 64; }

python3 - "$MANIFEST" "$ANSWER" <<'PY'
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path


manifest_path = Path(sys.argv[1])
answer_path = Path(sys.argv[2])


UUID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"
)
LABEL_RE = re.compile(
    r"\b(SOURCE_ID|SOURCE_PATH|SEED_FILE|DATA_ID|DATA_UUID|CHUNK_ID|CHUNK_UUID)\s*[:=]\s*"
    r"(?:\"([^\"]*)\"|'([^']*)'|([^\s,;\]\)]+))"
)


def _json(status, outcome, *, row=None, parsed=None, local=None, errors=None, warnings=None):
    parsed = parsed or {}
    row = row or {}
    local = local or {}
    errors = errors or []
    warnings = warnings or []
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    result = {
        "schema_version": "cognee_source_verification.v1",
        "event_type": "source_verification",
        "ts_utc": now,
        "operation": {
            "operation_name": "local_source_verify",
            "mutates_remote": False,
        },
        "source_reference": {
            "source_ids": sorted(parsed.get("source_ids", [])),
            "source_paths": sorted(parsed.get("source_paths", [])),
            "seed_files": sorted(parsed.get("seed_files", [])),
            "data_ids": sorted(parsed.get("data_ids", [])),
            "chunk_ids": sorted(parsed.get("chunk_ids", [])),
            "uuid_mentions": sorted(parsed.get("uuid_mentions", [])),
            "malformed_uuid_count": parsed.get("malformed_uuid_count", 0),
        },
        "manifest": {
            "manifest_path": str(manifest_path),
            "manifest_row_found": bool(row),
            "manifest_checksum_algorithm": "sha256" if _manifest_checksum(row) else None,
            "manifest_checksum_match": local.get("checksum_match"),
            "redaction_status": row.get("redaction_status"),
            "stale_risk": row.get("stale_risk"),
            "source_family": row.get("source_family"),
        },
        "local_file": {
            "local_file_opened": local.get("opened", False),
            "local_file_readable": local.get("readable", False),
            "local_file_size_bytes": local.get("size_bytes"),
            "local_file_mtime_utc": local.get("mtime_utc"),
        },
        "verification_result": {
            "status": status,
            "outcome": outcome,
            "errors": errors,
            "warnings": warnings,
        },
        "policy": {
            "cognee_is_source_of_truth": False,
            "action_authorized": False,
        },
    }
    print(json.dumps(result, sort_keys=True))
    _telemetry(result, row, local)


def _safe_label(value, default="unknown"):
    value = str(value or default)
    value = re.sub(r"[^A-Za-z0-9_.:-]+", "_", value.strip())[:120]
    return value or default


def _number_or_none(value):
    if value in (None, ""):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return int(number) if number.is_integer() else number


def _telemetry(result, row, local):
    telemetry_file = os.environ.get("FM_COGNEE_TELEMETRY_FILE")
    if not telemetry_file:
        return
    try:
        start_ms = int(os.environ.get("FM_COGNEE_TELEMETRY_START_MS") or 0)
    except ValueError:
        start_ms = 0
    latency_ms = max(int(time.time() * 1000) - start_ms, 0) if start_ms else 0
    try:
        path = Path(telemetry_file)
        path.parent.mkdir(parents=True, exist_ok=True)
        row = row or {}
        local = local or {}
        status = result.get("verification_result", {}).get("status")
        outcome = result.get("verification_result", {}).get("outcome")
        event = {
            "schema_version": "cognee_telemetry.v1",
            "ts_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "operation_name": "local_source_verify",
            "mode": "verify",
            "status": _safe_label(status),
            "error_class": "none" if status == "verified" else _safe_label(outcome),
            "retry_count": 0,
            "latency_ms": latency_ms,
            "imported_bytes": _number_or_none(local.get("size_bytes") or row.get("size_bytes")),
            "imported_tokens": _number_or_none(row.get("estimated_tokens")),
            "source_verification_outcome": _safe_label(outcome),
            "estimated_cost_usd": 0,
            "estimated_cost_status": "known_zero_local",
            "vendor_estimated_cost_usd": None,
            "vendor_cost_status": "not_called",
            "currency": "USD",
        }
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, sort_keys=True) + "\n")
    except Exception:
        return


def _load_manifest():
    rows = []
    with manifest_path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"manifest line {line_no} is not JSON: {exc}") from exc
            row["_line_no"] = line_no
            rows.append(row)
    return rows


def _parse_answer(text):
    labels = {
        "source_ids": set(),
        "source_paths": set(),
        "seed_files": set(),
        "data_ids": set(),
        "chunk_ids": set(),
        "uuid_mentions": set(),
    }
    malformed = 0
    for match in LABEL_RE.finditer(text):
        label = match.group(1)
        cleaned = next(group for group in match.groups()[1:] if group is not None).strip()
        if label == "SOURCE_ID":
            labels["source_ids"].add(cleaned)
        elif label == "SOURCE_PATH":
            labels["source_paths"].add(cleaned)
        elif label == "SEED_FILE":
            labels["seed_files"].add(cleaned)
        elif label in ("DATA_ID", "DATA_UUID"):
            if UUID_RE.fullmatch(cleaned):
                labels["data_ids"].add(cleaned.lower())
            else:
                malformed += 1
        elif label in ("CHUNK_ID", "CHUNK_UUID"):
            if UUID_RE.fullmatch(cleaned):
                labels["chunk_ids"].add(cleaned.lower())
            else:
                malformed += 1

    valid_labelled_uuids = labels["data_ids"] | labels["chunk_ids"]

    for value in UUID_RE.findall(text):
        lower = value.lower()
        if lower not in valid_labelled_uuids:
            labels["uuid_mentions"].add(lower)

    labels["malformed_uuid_count"] = malformed
    return labels


def _field_set(row, field):
    value = row.get(field)
    if value is None:
        return set()
    if isinstance(value, list):
        return {str(item) for item in value}
    return {str(value)}


def _lower_field_set(row, field):
    return {item.lower() for item in _field_set(row, field)}


def _source_path(row):
    return str(row.get("source_path") or row.get("path") or "")


def _seed_file(row):
    return str(row.get("seed_file") or "")


def _manifest_checksum(row):
    return row.get("checksum_sha256") or row.get("sha256") or row.get("checksum")


def _resolve_path(row):
    raw = _source_path(row)
    if not raw:
        return None
    path = Path(raw)
    if path.is_absolute():
        return path
    return (manifest_path.parent / path).resolve()


def _mtime_utc(path):
    return dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _find_row(rows, parsed):
    source_ids = parsed["source_ids"]
    if source_ids:
        for row in rows:
            if str(row.get("source_id")) in source_ids:
                return row
        return None

    source_paths = parsed["source_paths"]
    seed_files = parsed["seed_files"]
    data_ids = parsed["data_ids"] | parsed["uuid_mentions"]
    chunk_ids = parsed["chunk_ids"] | parsed["uuid_mentions"]
    for row in rows:
        if source_paths and (_source_path(row) in source_paths or str(_resolve_path(row)) in source_paths):
            return row
        if seed_files and _seed_file(row) in seed_files:
            return row
        if data_ids and data_ids & _lower_field_set(row, "data_ids"):
            return row
        if chunk_ids and chunk_ids & _lower_field_set(row, "chunk_ids"):
            return row
    return None


def _verify():
    if not manifest_path.is_file():
        _json("failed_closed", "failed_closed_manifest_unreadable", errors=[f"manifest not found: {manifest_path}"])
        return 2
    if not answer_path.is_file():
        _json("failed_closed", "failed_closed_answer_unreadable", errors=[f"answer not found: {answer_path}"])
        return 2

    try:
        rows = _load_manifest()
    except Exception as exc:
        _json("failed_closed", "failed_closed_manifest_unreadable", errors=[str(exc)])
        return 2

    try:
        answer_text = answer_path.read_text(encoding="utf-8")
    except Exception as exc:
        _json("failed_closed", "failed_closed_answer_unreadable", errors=[str(exc)])
        return 2

    parsed = _parse_answer(answer_text)
    has_reference = any(parsed[key] for key in ("source_ids", "source_paths", "seed_files", "data_ids", "chunk_ids", "uuid_mentions"))
    if not has_reference:
        _json("failed_closed", "failed_closed_missing_reference", parsed=parsed, errors=["no parseable source reference"])
        return 2

    row = _find_row(rows, parsed)
    if not row:
        _json("failed_closed", "hint_only_manifest_miss", parsed=parsed, errors=["no matching manifest row"])
        return 2

    errors = []
    warnings = []
    source_path = _resolve_path(row)
    local = {"opened": False, "readable": False, "checksum_match": None}

    row_source_id = {str(row.get("source_id"))}
    if parsed["source_ids"] - row_source_id:
        errors.append("SOURCE_ID does not match manifest row")
    row_raw_path = _source_path(row)
    row_resolved_path = str(source_path) if source_path else ""
    if parsed["source_paths"] - {row_raw_path, row_resolved_path}:
        errors.append("SOURCE_PATH does not match manifest row")
    if parsed["seed_files"] - {_seed_file(row)}:
        errors.append("SEED_FILE does not match manifest row")

    row_data_ids = _lower_field_set(row, "data_ids")
    row_chunk_ids = _lower_field_set(row, "chunk_ids")
    if parsed["data_ids"] - row_data_ids:
        errors.append("DATA_ID does not match manifest row")
    if parsed["chunk_ids"] - row_chunk_ids:
        errors.append("CHUNK_ID does not match manifest row")
    unknown_uuid_mentions = parsed["uuid_mentions"] - row_data_ids - row_chunk_ids
    if unknown_uuid_mentions:
        errors.append("UUID mention does not match manifest row")

    if not source_path or not source_path.is_file():
        errors.append("local source file is missing")
    else:
        try:
            local["opened"] = True
            local["readable"] = True
            local["size_bytes"] = source_path.stat().st_size
            local["mtime_utc"] = _mtime_utc(source_path)
            expected_size = row.get("size_bytes")
            if expected_size is not None and int(expected_size) != local["size_bytes"]:
                errors.append("local source size does not match manifest")
            expected_checksum = _manifest_checksum(row)
            if expected_checksum:
                local["checksum_match"] = _sha256(source_path).lower() == str(expected_checksum).lower()
                if not local["checksum_match"]:
                    errors.append("local source checksum does not match manifest")
        except Exception as exc:
            local["readable"] = False
            errors.append(f"local source file could not be read: {exc}")

    stale_risk = str(row.get("stale_risk") or "").lower()
    if stale_risk in {"high", "critical"}:
        warnings.append(f"stale_risk={stale_risk}")

    raw_status = str(row.get("raw_readback_status") or row.get("raw_status") or "ok").lower()
    raw_blocked = raw_status not in {"", "ok", "passed", "available", "readable", "200"}
    if raw_blocked:
        errors.append(f"raw_readback_status={raw_status}")

    if errors:
        if any("checksum" in error for error in errors):
            outcome = "failed_closed_checksum_mismatch"
        elif any("raw_readback_status" in error for error in errors):
            outcome = "failed_closed_raw_durability"
        elif any("DATA_ID" in error or "CHUNK_ID" in error or "UUID" in error for error in errors):
            outcome = "failed_closed_identifier_mismatch"
        elif any("SOURCE_PATH" in error for error in errors):
            outcome = "failed_closed_path_mismatch"
        elif any("SEED_FILE" in error for error in errors):
            outcome = "failed_closed_seed_mismatch"
        elif any("local source" in error for error in errors):
            outcome = "failed_closed_missing_proof"
        else:
            outcome = "failed_closed_missing_proof"
        _json("failed_closed", outcome, row=row, parsed=parsed, local=local, errors=errors, warnings=warnings)
        return 2

    _json("verified", "verified_local_source", row=row, parsed=parsed, local=local, warnings=warnings)
    return 0


sys.exit(_verify())
PY
