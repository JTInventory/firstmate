#!/usr/bin/env bash
# Real AF_UNIX/SO_PEERCRED coverage for the per-home authority broker.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROKER="$ROOT/bin/fm-session-authority-broker.py"
TMP_ROOT=$(fm_test_tmproot fm-session-authority-broker)
HOME_DIR="$TMP_ROOT/home"
FOREIGN_HOME="$TMP_ROOT/foreign"
STATE="$HOME_DIR/state"
RECORD="$STATE/.session-authority-broker"
BROKER_PID=
LAUNCH_PID=
PRIMARY_PID=
PRIMARY_HARNESS_PID=
SIGNER_PID=
ROTATION_PRIMARY_SETUP_PID=
ROTATION_CUSTODIAN_PID=
ROTATION_DURABLE_KEY=
CONCURRENT_EVIDENCE_WRITER_ONE=
CONCURRENT_EVIDENCE_WRITER_TWO=
CONCURRENT_ACK_READER_ONE=
CONCURRENT_ACK_READER_TWO=
CONCURRENT_ACK_COLLECTOR=
CONCURRENT_START_ACK_COLLECTOR=
CONCURRENT_RELEASE_WRITER_ONE=
CONCURRENT_RELEASE_WRITER_TWO=
CONCURRENT_REQUEST_ONE=
CONCURRENT_REQUEST_TWO=
CONCURRENT_CALLER_READER_ONE=
CONCURRENT_CALLER_READER_TWO=
CONCURRENT_OUTPUT_READER_ONE=
CONCURRENT_OUTPUT_READER_TWO=
CONCURRENT_STATUS_READER_ONE=
CONCURRENT_STATUS_READER_TWO=
CONCURRENT_FIXTURE_STATE=
CONCURRENT_FIXTURE_ROOT=
CONCURRENT_PUBLISHED_BROKER_PID=
REQUEST_FIFO=
PRIMARY_REQUEST_FIFO=
REQUEST_SEQUENCE=0
BROKER_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

reap_concurrent_broker() {
  local state=$CONCURRENT_FIXTURE_STATE
  local pid=$CONCURRENT_PUBLISHED_BROKER_PID
  local pids candidate args
  if [ -z "$pid" ] && [ -n "$state" ] && [ -f "$state/.session-authority-broker" ]; then
    pid=$(sed -n '2s/^pid=//p' "$state/.session-authority-broker")
  fi
  [ -n "$state" ] || return 0
  pids=$(ps -eo pid=,args= | awk -v state="$state" \
    '$0 ~ /fm-session-authority-broker.py/ && index($0, state) {print $1}')
  for candidate in $pid $pids; do
    case "$candidate" in
      ''|*[!0-9]*) continue ;;
    esac
    args=$(ps -p "$candidate" -o args= 2>/dev/null || true)
    case "$args" in
      *fm-session-authority-broker.py*"$state"*) ;;
      *) continue ;;
    esac
    kill "$candidate" 2>/dev/null || true
    if ! timeout 5 tail --pid="$candidate" -f /dev/null 2>/dev/null; then
      kill -KILL "$candidate" 2>/dev/null || true
    fi
    wait "$candidate" 2>/dev/null || true
  done
  CONCURRENT_PUBLISHED_BROKER_PID=
}

terminate_owned_process() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  kill -TERM "$pid" 2>/dev/null || true
  if timeout 5 tail --pid="$pid" -f /dev/null 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    return 0
  fi
  kill -KILL "$pid" 2>/dev/null || true
  timeout 5 tail --pid="$pid" -f /dev/null 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

evidence_validate_decimal() {
  local value=$1 max_length=${2:-10}
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#value}" -le "$max_length" ]
}

evidence_validate_generation() {
  [[ "$1" =~ ^proc:[0-9]{1,20}$ ]]
}

evidence_validate_text() {
  local value=$1
  [ -n "$value" ] && [ "${#value}" -le 4096 ] || return 1
  if LC_ALL=C printf '%s' "$value" | LC_ALL=C grep -q '[^[:print:]]'; then
    return 1
  fi
}

evidence_sha256() {
  local value=$1 digest
  digest=$(printf '%s' "$value" | sha256sum 2>/dev/null) || return 1
  digest=${digest%% *}
  case "$digest" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "$digest"
}

preserve_failure_evidence() {
  local status=$1 parent=/tmp/no-mistakes-evidence
  local evidence_tmp evidence state record path base index=0 tmp_name
  local value state_suffix scan_status line key seen_keys record_count record_invalid
  local record_version record_pid record_start record_identity record_socket
  local record_home record_checkout record_task record_script record_uid
  local record_gid record_launch_pid record_launch_start record_launch_identity
  local record_launch_script record_state_label
  local record_identity_hash record_socket_hash record_home_hash
  local record_checkout_hash record_task_hash record_script_hash
  local record_launch_identity_hash record_launch_script_hash known_secret
  local bundle_file bundle_base
  local state_root process_snapshot process_rows process_row_count
  evidence_validate_decimal "$status" 3 || return 1
  mkdir -p "$parent" 2>/dev/null || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  evidence_tmp=$(mktemp -d \
    "$parent/.fm-session-authority-broker.partial.XXXXXX" \
    2>/dev/null) || return 1
  if [ ! -d "$evidence_tmp" ] || [ -L "$evidence_tmp" ]; then
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  fi
  tmp_name=$(basename -- "$evidence_tmp") || {
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  }
  evidence="$parent/${tmp_name#.}"
  if [ -e "$evidence" ]; then
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  fi
  if [ -n "$CONCURRENT_FIXTURE_STATE" ]; then
    [ -n "$CONCURRENT_FIXTURE_ROOT" ] \
      && [ "$CONCURRENT_FIXTURE_STATE" = "$CONCURRENT_FIXTURE_ROOT/state" ] || {
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    }
    printf '<fixture>/state\n' > "$evidence_tmp/concurrent-state" || {
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    }
  else
    printf 'none\n' > "$evidence_tmp/concurrent-state" || {
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    }
  fi
  process_snapshot="$evidence_tmp/process-snapshot"
  process_rows="$evidence_tmp/process-rows"
  if ! {
    printf '%s\n' "$status" > "$evidence_tmp/exit-status" \
      && [ -f "$evidence_tmp/concurrent-state" ] \
      && [ ! -L "$evidence_tmp/concurrent-state" ] \
      && ps -eo pid=,ppid=,stat= > "$process_snapshot" 2>/dev/null \
      && [ -f "$process_snapshot" ] \
      && [ ! -L "$process_snapshot" ] \
      && awk '
        NF != 3 ||
        $1 !~ /^[0-9][0-9]*$/ || length($1) > 10 ||
        $2 !~ /^[0-9][0-9]*$/ || length($2) > 10 ||
        $3 !~ /^[[:alnum:]_+<>=~-]+$/ || length($3) > 8 { exit 1 }
        { print $1, $2, $3 }
      ' "$process_snapshot" > "$process_rows" \
      && [ -f "$process_rows" ] \
      && [ ! -L "$process_rows" ]
  }; then
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  fi
  process_row_count=$(wc -l < "$process_rows") || {
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  }
  process_row_count=${process_row_count//[[:space:]]/}
  evidence_validate_decimal "$process_row_count" 10 || {
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  }
  if [ "$process_row_count" -eq 0 ]; then
    printf 'ps-success-zero-rows\n' > "$evidence_tmp/processes-zero-rows" || {
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    }
  else
    {
      printf 'pid ppid stat\n'
      cat -- "$process_rows"
    } > "$evidence_tmp/processes" || {
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    }
  fi
  rm -f -- "$process_snapshot" "$process_rows" || {
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  }
  for state in "$CONCURRENT_FIXTURE_STATE" "$STATE"; do
    [ -n "$state" ] || continue
    state_root=$TMP_ROOT
    if [ -n "$CONCURRENT_FIXTURE_STATE" ] \
      && [ "$state" = "$CONCURRENT_FIXTURE_STATE" ]; then
      state_root=$CONCURRENT_FIXTURE_ROOT
    fi
    [ -n "$state_root" ] || {
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    }
    case "$state" in
      "$state_root"|"$state_root"/*) ;;
      *)
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
        ;;
    esac
    [ -d "$state" ] || continue
    [ ! -L "$state" ] || {
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    }
    state_suffix=${state#"$state_root"}
    [[ "$state_suffix" =~ ^(/[A-Za-z0-9._-]+)+$ ]] \
      && [ "${#state_suffix}" -le 512 ] || {
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    }
    record_state_label="<fixture>$state_suffix"
    index=$((index + 1))
    record="$state/.session-authority-broker"
    if [ -e "$record" ] || [ -L "$record" ]; then
      [ -f "$record" ] && [ ! -L "$record" ] || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      [ "$(wc -c < "$record")" -le 8192 ] || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      record_version= record_pid= record_start= record_identity=
      record_socket= record_home= record_checkout= record_task=
      record_script= record_uid= record_gid= record_launch_pid=
      record_launch_start= record_launch_identity= record_launch_script=
      seen_keys= record_count=0 record_invalid=0
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *=*)
            key=${line%%=*}
            value=${line#*=}
            ;;
          *)
            record_invalid=1
            continue
            ;;
        esac
        case "$key" in
          version|pid|start|identity|socket|home|checkout|task|script|uid|gid|launch-pid|launch-start|launch-identity|launch-script)
            case "|$seen_keys|" in
              *"|$key|"*)
                record_invalid=1
                continue
                ;;
            esac
            seen_keys="$seen_keys|$key"
            record_count=$((record_count + 1))
            case "$key" in
              version) record_version=$value ;;
              pid) record_pid=$value ;;
              start) record_start=$value ;;
              identity) record_identity=$value ;;
              socket) record_socket=$value ;;
              home) record_home=$value ;;
              checkout) record_checkout=$value ;;
              task) record_task=$value ;;
              script) record_script=$value ;;
              uid) record_uid=$value ;;
              gid) record_gid=$value ;;
              launch-pid) record_launch_pid=$value ;;
              launch-start) record_launch_start=$value ;;
              launch-identity) record_launch_identity=$value ;;
              launch-script) record_launch_script=$value ;;
            esac
            ;;
          *)
            record_invalid=1
            ;;
        esac
      done < "$record"
      [ "$record_invalid" -eq 0 ] && [ "$record_count" -eq 15 ] \
        && [ "$record_version" = 1 ] \
        && evidence_validate_decimal "$record_pid" \
        && evidence_validate_decimal "$record_uid" \
        && evidence_validate_decimal "$record_gid" \
        && evidence_validate_decimal "$record_launch_pid" \
        && evidence_validate_generation "$record_start" \
        && evidence_validate_generation "$record_launch_start" \
        && evidence_validate_text "$record_identity" \
        && evidence_validate_text "$record_socket" \
        && evidence_validate_text "$record_home" \
        && evidence_validate_text "$record_checkout" \
        && evidence_validate_text "$record_task" \
        && evidence_validate_text "$record_script" \
        && evidence_validate_text "$record_launch_identity" \
        && evidence_validate_text "$record_launch_script" || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      case "$record_identity" in exe:/*) ;; *)
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
        ;; esac
      case "$record_launch_identity" in exe:/*) ;; *)
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
        ;; esac
      case "$record_home:$record_checkout:$record_script:$record_launch_script" in
        /*:/*:/*:/*) ;;
        *)
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
          ;;
      esac
      case "$record_socket" in abstract:*|/*) ;; *)
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
        ;; esac
      record_identity_hash=$(evidence_sha256 "$record_identity") || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      record_socket_hash=$(evidence_sha256 "$record_socket") || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      record_home_hash=$(evidence_sha256 "$record_home") || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      record_checkout_hash=$(evidence_sha256 "$record_checkout") || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      record_task_hash=$(evidence_sha256 "$record_task") || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      record_script_hash=$(evidence_sha256 "$record_script") || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      record_launch_identity_hash=$(evidence_sha256 "$record_launch_identity") || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      record_launch_script_hash=$(evidence_sha256 "$record_launch_script") || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      {
        printf 'status=record-present\n'
        printf 'version=1\n'
        printf 'pid=%s\n' "$record_pid"
        printf 'start=%s\n' "$record_start"
        printf 'launch-pid=%s\n' "$record_launch_pid"
        printf 'launch-start=%s\n' "$record_launch_start"
        printf 'uid=%s\n' "$record_uid"
        printf 'gid=%s\n' "$record_gid"
        printf 'state=%s\n' "$record_state_label"
        printf 'identity-sha256=%s\n' "$record_identity_hash"
        printf 'socket-sha256=%s\n' "$record_socket_hash"
        printf 'home-sha256=%s\n' "$record_home_hash"
        printf 'checkout-sha256=%s\n' "$record_checkout_hash"
        printf 'task-sha256=%s\n' "$record_task_hash"
        printf 'script-sha256=%s\n' "$record_script_hash"
        printf 'launch-identity-sha256=%s\n' "$record_launch_identity_hash"
        printf 'launch-script-sha256=%s\n' "$record_launch_script_hash"
      } > "$evidence_tmp/record-$index" || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      [ -f "$evidence_tmp/record-$index" ] \
        && [ ! -L "$evidence_tmp/record-$index" ] || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
    fi
    for path in \
      "$state/concurrent-broker-first" \
      "$state/concurrent-broker-second" \
      "$state/concurrent-broker-first.capture" \
      "$state/concurrent-broker-second.capture" \
      "$state/concurrent-broker-first.status.capture" \
      "$state/concurrent-broker-second.status.capture" \
      "$state/.test-start-barrier-ack" \
      "$state/.test-supervisor-ack-1"; do
      [ -f "$path" ] && [ ! -L "$path" ] || continue
      base=$(basename -- "$path") || {
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
      }
      case "$base" in
        concurrent-broker-first|concurrent-broker-second|\
        concurrent-broker-first.capture|concurrent-broker-second.capture|\
        concurrent-broker-first.status.capture|\
        concurrent-broker-second.status.capture)
          value=$(cat -- "$path") || {
            rm -rf -- "$evidence_tmp" 2>/dev/null || true
            return 1
          }
          case "$value" in
            ''|*[!0-9]*)
              rm -rf -- "$evidence_tmp" 2>/dev/null || true
              return 1
              ;;
          esac
          printf '%s\n' "$value" > \
            "$evidence_tmp/state-$index-$base" || {
            rm -rf -- "$evidence_tmp" 2>/dev/null || true
            return 1
          }
          ;;
        .test-start-barrier-ack)
          awk -F '|' '
            {
              if (NF != 2 || ($1 != "1" && $1 != "2") ||
                  $2 !~ /^CONTEND pid=[0-9]+$/ || seen[$1]) {
                invalid = 1
                next
              }
              seen[$1] = 1
              line[$1] = $0
              count++
            }
            END {
              if (invalid || count != 2 || !seen[1] || !seen[2]) {
                exit 1
              }
              print line[1]
              print line[2]
            }
          ' "$path" > "$evidence_tmp/state-$index-$base" || {
            rm -rf -- "$evidence_tmp" 2>/dev/null || true
            return 1
          }
          ;;
        .test-supervisor-ack-1)
          awk '
            NR == 1 {
              if ($0 !~ /^[12]$/) invalid = 1
              slot = $0
              next
            }
            NR == 2 {
              if ($0 !~ /^READY pid=[0-9]+$/) invalid = 1
              ready = $0
              next
            }
            { invalid = 1 }
            END {
              if (invalid || NR != 2 || slot == "" || ready == "") {
                exit 1
              }
              print slot
              print ready
            }
          ' "$path" > "$evidence_tmp/state-$index-$base" || {
            rm -rf -- "$evidence_tmp" 2>/dev/null || true
            return 1
          }
          ;;
        *)
          continue
          ;;
      esac
      [ -f "$evidence_tmp/state-$index-$base" ] \
        && [ ! -L "$evidence_tmp/state-$index-$base" ] || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
    done
  done
  printf 'complete\n' > "$evidence_tmp/complete" || {
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  }
  [ -f "$evidence_tmp/complete" ] && [ ! -L "$evidence_tmp/complete" ] || {
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  }
  while IFS= read -r bundle_file; do
    [ -f "$bundle_file" ] && [ ! -L "$bundle_file" ] || {
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    }
    bundle_base=${bundle_file##*/}
    case "$bundle_base" in
      concurrent-state)
        awk 'NR == 1 && ($0 == "none" ||
          $0 ~ /^<fixture>(\/[A-Za-z0-9._-]+)+$/) { valid = 1 }
          NR > 1 { invalid = 1 }
          END { exit !(valid && !invalid) }' "$bundle_file" || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
        ;;
      exit-status)
        awk 'NR == 1 && $0 ~ /^[0-9][0-9]*$/ && length($0) <= 3 { valid = 1 }
          NR > 1 { invalid = 1 }
          END { exit !(valid && !invalid) }' "$bundle_file" || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
        ;;
      processes)
        awk 'NR == 1 && $0 == "pid ppid stat" { next }
          NR == 1 { invalid = 1; next }
          $1 !~ /^[0-9][0-9]*$/ || length($1) > 10 ||
          $2 !~ /^[0-9][0-9]*$/ || length($2) > 10 ||
          $3 !~ /^[[:alnum:]_+<>=~-]+$/ || length($3) > 8 { invalid = 1 }
          END { if (NR < 2) invalid = 1; exit invalid }' "$bundle_file" || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
        ;;
      processes-zero-rows)
        [ "$(cat -- "$bundle_file" 2>/dev/null)" = "ps-success-zero-rows" ] || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
        ;;
      record-[1-9]|record-[1-9][0-9]*)
        awk -F '=' '
          BEGIN {
            expected["status"] = 1
            expected["version"] = 1
            expected["pid"] = 1
            expected["start"] = 1
            expected["launch-pid"] = 1
            expected["launch-start"] = 1
            expected["uid"] = 1
            expected["gid"] = 1
            expected["state"] = 1
            expected["identity-sha256"] = 1
            expected["socket-sha256"] = 1
            expected["home-sha256"] = 1
            expected["checkout-sha256"] = 1
            expected["task-sha256"] = 1
            expected["script-sha256"] = 1
            expected["launch-identity-sha256"] = 1
            expected["launch-script-sha256"] = 1
          }
          {
            if (NF != 2 || !($1 in expected) || seen[$1]++) {
              invalid = 1
              next
            }
            if ($1 == "status" && $2 != "record-present") invalid = 1
            if ($1 == "version" && $2 != "1") invalid = 1
            if ($1 ~ /(^|-)pid$/ &&
                ($2 !~ /^[0-9][0-9]*$/ || length($2) > 10)) invalid = 1
            if ($1 ~ /(^|-)start$/ &&
                ($2 !~ /^proc:[0-9][0-9]*$/ || length($2) > 25)) invalid = 1
            if ($1 == "state" &&
                $2 !~ /^<fixture>(\/[A-Za-z0-9._-]+)+$/) invalid = 1
            if ($1 ~ /-sha256$/ &&
                ($2 !~ /^[0-9a-f][0-9a-f]*$/ || length($2) != 64)) invalid = 1
            count++
          }
          END {
            for (key in expected) if (!(key in seen)) invalid = 1
            if (count != 17) invalid = 1
            exit invalid
          }' "$bundle_file" || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
        ;;
      state-*-concurrent-broker-first|state-*-concurrent-broker-second|\
      state-*-concurrent-broker-first.capture|state-*-concurrent-broker-second.capture|\
      state-*-concurrent-broker-first.status.capture|\
      state-*-concurrent-broker-second.status.capture)
        awk 'NR == 1 && $0 ~ /^[0-9][0-9]*$/ && length($0) <= 10 { valid = 1 }
          NR > 1 { invalid = 1 }
          END { exit !(valid && !invalid) }' "$bundle_file" || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
        ;;
      state-*.test-start-barrier-ack)
        awk -F '|' '
          {
            if (NF != 2 || ($1 != "1" && $1 != "2") ||
                $2 !~ /^CONTEND pid=[0-9][0-9]*$/ || seen[$1]++) {
              invalid = 1
            }
            count++
          }
          END {
            if (invalid || count != 2 || !seen[1] || !seen[2]) exit 1
          }' "$bundle_file" || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
        ;;
      state-*.test-supervisor-ack-1)
        awk 'NR == 1 && $0 ~ /^[12]$/ { slot = $0; next }
          NR == 2 && $0 ~ /^READY pid=[0-9][0-9]*$/ { ready = 1; next }
          { invalid = 1 }
          END { exit !(NR == 2 && slot != "" && ready && !invalid) }' \
          "$bundle_file" || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
        ;;
      complete)
        [ "$(cat -- "$bundle_file")" = complete ] || {
          rm -rf -- "$evidence_tmp" 2>/dev/null || true
          return 1
        }
        ;;
      *)
        rm -rf -- "$evidence_tmp" 2>/dev/null || true
        return 1
        ;;
    esac
  done < <(find "$evidence_tmp" -maxdepth 1 -type f -print)
  for known_secret in "${BROKER_KEY:-}" "${ROTATION_DURABLE_KEY:-}"; do
    [ -n "$known_secret" ] || continue
    if grep -R -F -I -n -- "$known_secret" "$evidence_tmp" >/dev/null 2>&1; then
      rm -rf -- "$evidence_tmp" 2>/dev/null || true
      return 1
    fi
  done
  grep -R -E -I -i -n \
    -e '-----BEGIN|-----END|private[-_]?key|public[-_]?key|consumer[-_]?key|enrollment|nonce|token|secret|authority-hmac|signature' \
    "$evidence_tmp" >/dev/null 2>&1
  scan_status=$?
  if [ "$scan_status" -eq 0 ] || [ "$scan_status" -gt 1 ]; then
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  fi
  mv -- "$evidence_tmp" "$evidence" || {
    rm -rf -- "$evidence_tmp" 2>/dev/null || true
    return 1
  }
  [ -d "$evidence" ] && [ ! -L "$evidence" ] \
    && [ -f "$evidence/complete" ] && [ ! -L "$evidence/complete" ] || {
      rm -rf -- "$evidence" 2>/dev/null || true
      return 1
    }
}

cleanup() {
  local exit_status=$? evidence_status=0
  if [ "$exit_status" -ne 0 ] \
    && ! preserve_failure_evidence "$exit_status"; then
    evidence_status=1
    printf '%s\n' \
      'fm-session-authority-broker: failure evidence preservation failed; fixture retained' \
      >&2
  fi
  [ -z "$BROKER_PID" ] || kill_owned_process_tree "$BROKER_PID"
  reap_concurrent_broker
  [ -z "$LAUNCH_PID" ] || kill_owned_process_tree "$LAUNCH_PID"
  [ -z "$SIGNER_PID" ] || kill_owned_process_tree "$SIGNER_PID"
  [ -z "$PRIMARY_PID" ] || kill_owned_process_tree "$PRIMARY_PID"
  [ -z "$PRIMARY_HARNESS_PID" ] \
    || kill_owned_process_tree "$PRIMARY_HARNESS_PID"
  [ -z "$ROTATION_PRIMARY_SETUP_PID" ] \
    || kill_owned_process_tree "$ROTATION_PRIMARY_SETUP_PID"
  [ -z "$ROTATION_CUSTODIAN_PID" ] \
    || kill_owned_process_tree "$ROTATION_CUSTODIAN_PID"
  [ -z "$CONCURRENT_EVIDENCE_WRITER_ONE" ] \
    || kill_owned_process_tree "$CONCURRENT_EVIDENCE_WRITER_ONE"
  [ -z "$CONCURRENT_EVIDENCE_WRITER_TWO" ] \
    || kill_owned_process_tree "$CONCURRENT_EVIDENCE_WRITER_TWO"
  [ -z "$CONCURRENT_ACK_READER_ONE" ] \
    || kill_owned_process_tree "$CONCURRENT_ACK_READER_ONE"
  [ -z "$CONCURRENT_ACK_READER_TWO" ] \
    || kill_owned_process_tree "$CONCURRENT_ACK_READER_TWO"
  [ -z "$CONCURRENT_ACK_COLLECTOR" ] \
    || kill_owned_process_tree "$CONCURRENT_ACK_COLLECTOR"
  [ -z "$CONCURRENT_START_ACK_COLLECTOR" ] \
    || kill_owned_process_tree "$CONCURRENT_START_ACK_COLLECTOR"
  [ -z "$CONCURRENT_RELEASE_WRITER_ONE" ] \
    || kill_owned_process_tree "$CONCURRENT_RELEASE_WRITER_ONE"
  [ -z "$CONCURRENT_RELEASE_WRITER_TWO" ] \
    || kill_owned_process_tree "$CONCURRENT_RELEASE_WRITER_TWO"
  [ -z "$CONCURRENT_REQUEST_ONE" ] \
    || kill_owned_process_tree "$CONCURRENT_REQUEST_ONE"
  [ -z "$CONCURRENT_REQUEST_TWO" ] \
    || kill_owned_process_tree "$CONCURRENT_REQUEST_TWO"
  [ -z "$CONCURRENT_CALLER_READER_ONE" ] \
    || kill_owned_process_tree "$CONCURRENT_CALLER_READER_ONE"
  [ -z "$CONCURRENT_CALLER_READER_TWO" ] \
    || kill_owned_process_tree "$CONCURRENT_CALLER_READER_TWO"
  [ -z "$CONCURRENT_OUTPUT_READER_ONE" ] \
    || kill_owned_process_tree "$CONCURRENT_OUTPUT_READER_ONE"
  [ -z "$CONCURRENT_OUTPUT_READER_TWO" ] \
    || kill_owned_process_tree "$CONCURRENT_OUTPUT_READER_TWO"
  [ -z "$CONCURRENT_STATUS_READER_ONE" ] \
    || kill_owned_process_tree "$CONCURRENT_STATUS_READER_ONE"
  [ -z "$CONCURRENT_STATUS_READER_TWO" ] \
    || kill_owned_process_tree "$CONCURRENT_STATUS_READER_TWO"
  for pid in "${FM_TEST_AUTHORITY_BROKER_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill_owned_process_tree "$pid"
  done
  FM_TEST_AUTHORITY_BROKER_PIDS=()
  reap_concurrent_broker
  if [ "$evidence_status" -eq 0 ]; then
    fm_test_cleanup || true
  else
    printf '%s\n' \
      'fm-session-authority-broker: cleanup skipped because fixture evidence was not captured' \
      >&2
  fi
  [ "$evidence_status" -eq 0 ] || return 1
  return "$exit_status"
}
trap cleanup EXIT

kill_owned_process_tree() {
  local root=$1 child
  for child in $(ps -eo pid=,ppid= | awk -v parent="$root" '$2 == parent {print $1}'); do
    kill_owned_process_tree "$child"
  done
  terminate_owned_process "$root"
}

test_process_start() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path

line = Path(f"/proc/{sys.argv[1]}/stat").read_text()
print(f"proc:{line[line.rfind(')') + 2:].split()[19]}")
PY
}

test_process_identity() {
  printf 'exe:%s' "$(readlink "/proc/$1/exe")"
}

test_sha256_file() {
  local output digest
  output=$(openssl dgst -sha256 "$1" 2>/dev/null) || return 1
  digest=${output##*= }
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "$digest"
}

test_broker_client_deadline_covers_connect_and_send() {
  local source first_timeout connect second_timeout send
  source=$(sed -n '/^def client(/,/^def parse_args/p' "$BROKER")
  first_timeout=$(printf '%s\n' "$source" | grep -n 'connection.settimeout(BROKER_REQUEST_TIMEOUT_SECONDS)' | head -1 | cut -d: -f1)
  connect=$(printf '%s\n' "$source" | grep -n 'connection.connect(' | head -1 | cut -d: -f1)
  second_timeout=$(printf '%s\n' "$source" | grep -n 'connection.settimeout(timeout)' | head -1 | cut -d: -f1)
  send=$(printf '%s\n' "$source" | grep -n 'connection.sendall' | head -1 | cut -d: -f1)
  [ -n "$first_timeout" ] && [ -n "$connect" ] && [ "$first_timeout" -lt "$connect" ] \
    || fail "broker client did not bound AF_UNIX connect"
  [ -n "$second_timeout" ] && [ -n "$send" ] && [ "$second_timeout" -lt "$send" ] \
    || fail "broker client did not bound request send"
  pass "broker client applies its deadline before connect and send"
}

test_broker_client_deadline_covers_connect_and_send

test_broker_client_deadline_is_behavioral() {
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import io
import sys
from types import SimpleNamespace

broker_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("session_authority_broker_deadline", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

broker.read_record = lambda _path: {"socket": "abstract:test"}
broker.connected_peer_matches_record = lambda _connection, _metadata: True

class FakeConnection:
    def __init__(self, mode):
        self.mode = mode
        self.timeouts = []

    def settimeout(self, value):
        self.timeouts.append(value)

    def connect(self, _address):
        if self.mode == "connect":
            raise TimeoutError("connect stalled")

    def sendall(self, _payload):
        raise TimeoutError("send stalled")

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

def run(mode, clock):
    connection = FakeConnection(mode)
    broker.socket.socket = lambda *_args: connection
    broker.time.monotonic = lambda: clock.pop(0)
    broker.sys.stdin = io.TextIOWrapper(io.BytesIO(b"body"))
    status = broker.client(SimpleNamespace(record="unused", kind="live"))
    if status != 1:
        raise SystemExit(f"{mode} stall returned {status}")
    return connection.timeouts

connect_timeouts = run("connect", [100.0])
if connect_timeouts != [broker.BROKER_REQUEST_TIMEOUT_SECONDS]:
    raise SystemExit(f"connect deadline missing: {connect_timeouts}")

send_timeouts = run("send", [100.0, 100.1])
if len(send_timeouts) != 2 or send_timeouts[1] <= 0:
    raise SystemExit(f"send deadline missing: {send_timeouts}")
PY
  then
    fail "broker connect/send deadline behavior regressed"
  fi
  pass "broker connect and send stalls honor the request deadline"
}

test_inherited_capability_requires_anonymous_pipe() {
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location(
    "session_authority_broker_capability_type", broker_path
)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    named = Path(temporary) / "capability"
    os.mkfifo(named, 0o600)
    named_fd = os.open(named, os.O_RDWR | os.O_NONBLOCK)
    try:
        os.write(named_fd, b"a" * 96 + b"\n")
        try:
            broker.read_inherited_capability(named_fd)
        except ValueError:
            pass
        else:
            raise SystemExit("a filesystem FIFO was accepted as authority")
    finally:
        os.close(named_fd)

    reopened_fd = os.open(named, os.O_RDWR | os.O_NONBLOCK)
    try:
        os.write(reopened_fd, b"a" * 96 + b"\n")
        try:
            broker.read_inherited_capability(reopened_fd)
        except ValueError:
            pass
        else:
            raise SystemExit("a named capability was replayed after reopen")
    finally:
        os.close(reopened_fd)

    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, b"a" * 96 + b"\n")
        os.close(write_fd)
        write_fd = -1
        if broker.read_inherited_capability(read_fd) != "a" * 96:
            raise SystemExit("an anonymous capability was not accepted")
    finally:
        os.close(read_fd)
        if write_fd >= 0:
            os.close(write_fd)
PY
  then
    fail "named FIFO capability was accepted or anonymous pipe was rejected"
  fi
  pass "admission capabilities require unnameable anonymous pipes"
}

test_primary_authority_record_and_live_descriptor_binding() {
  local fixture state authority backup
  fixture=$(fm_test_tmproot fm-primary-authority-binding)
  state="$fixture/state"
  authority="$state/.session-authority"
  backup="$fixture/authority.backup"
  mkdir -p "$state"
  (
    cd "$ROOT" || exit 1
    . "$ROOT/bin/fm-session-lock-lib.sh"
    exec 9< <(while :; do printf '%s\n' \
      0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef; done)
    exec 18< <(while :; do printf '%s\n' \
      fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210; done)
    export FM_HOME="$ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state"
    export FM_SESSION_AUTHORITY_FD=9 FM_SESSION_AUTHORITY_DURABLE_FD=18
    fm_session_authority_write_file "$authority" "$$" "$$" "$ROOT" "$ROOT"
    printf '%s\n' "$ROOT" > "$state/.primary-checkout"
    printf '%s\n' "$$" > "$state/.lock"
    fm_session_authority_live_binding_write "$state"
    fm_session_authority_live_binding_validate "$state" "$$" 9
    cp "$authority" "$backup"
    sed 's/^owner=.*/owner=forged/' "$authority" > "$authority.tmp"
    mv "$authority.tmp" "$authority"
    if fm_session_authority_read "$authority"; then
      exit 1
    fi
    cp "$backup" "$authority"
    exec 9< <(while :; do printf '%s\n' \
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done)
    if fm_session_authority_live_binding_validate "$state" "$$" 9; then
      exit 1
    fi
    exec 9<&-
    unset FM_SESSION_AUTHORITY_FD
    old_pid=$$
    export ROOT FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
      FM_SESSION_AUTHORITY_DURABLE_FD=18 \
      FM_ROTATION_RESULT="$state/rotation.result"
    if bash -c '
      set -u
      . "$ROOT/bin/fm-session-lock-lib.sh"
      fm_session_authority_live_descriptor_rotate
    ' 9<&-; then
      exit 1
    fi
    [ ! -e "$state/rotation.result" ] || exit 1
    [ "$old_pid" = "$$" ] || exit 1
  )
  pass "durable authority records bind rewrites and reject untrusted rotation"
}

test_primary_wrapper_rotates_dead_authority() {
  local fixture authority first_pid second_pid
  fixture=$(fm_test_tmproot fm-primary-wrapper-rotation)
  mkdir -p "$fixture/bin"
  (
    sleep 3
    fm_git_init_commit "$fixture"
    git -C "$fixture" branch -M main
    cp -R "$ROOT/bin/." "$fixture/bin/"
    chmod 700 "$fixture/bin"/*.sh "$fixture/bin"/*.py
    cd "$fixture" || exit 1
    exec 9<&- 18<&- 2>/dev/null || true
    env -u FM_SESSION_AUTHORITY_FD -u FM_SESSION_AUTHORITY_DURABLE_FD \
      FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" \
      FM_STATE_OVERRIDE="$fixture/state" \
      "$fixture/bin/fm-session-authority-exec.sh" bash -c ':' >/dev/null 2>&1
  ) || fail "primary wrapper could not create its protected authority"
  authority="$fixture/state/.session-authority"
  first_pid=$(sed -n '2s/^pid=//p' "$authority")
  kill -0 "$first_pid" 2>/dev/null && fail "first primary wrapper remained alive"
  [ -f "$fixture/state/.session-durable-authority" ] \
    || fail "primary wrapper did not publish durable recovery authority"
  (
    cd "$fixture" || exit 1
    exec 9<&- 18<&- 2>/dev/null || true
    env -u FM_SESSION_AUTHORITY_FD -u FM_SESSION_AUTHORITY_DURABLE_FD \
      FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" \
      FM_STATE_OVERRIDE="$fixture/state" \
      "$fixture/bin/fm-session-authority-exec.sh" bash -c ':' >/dev/null 2>&1
  ) || fail "primary wrapper could not rotate dead authority"
  second_pid=$(sed -n '2s/^pid=//p' "$authority")
  [ "$first_pid" != "$second_pid" ] \
    || fail "primary wrapper did not publish a new authority generation"
  [ "$(sed -n '2s/^pid=//p' "$fixture/state/.session-authority-live")" = \
    "$second_pid" ] || fail "rotated authority live binding was not published"
  [ ! -e "$fixture/state/.session-authority-transaction" ] \
    || fail "rotated authority left committed transaction evidence"
  pass "trusted wrapper rotates dead primary authority"
}

test_concurrent_primary_cold_start_has_one_winner() {
  local fixture first_output second_output first_pid second_pid
  local first_status second_status winners attempts custodian_pid status
  local root_generations root_key_calls random_calls
  fixture=$(fm_test_tmproot fm-concurrent-primary-cold-start)
  mkdir -p "$fixture/bin" "$fixture/test-bin"
  sleep 2
  fm_git_init_commit "$fixture"
  git -C "$fixture" branch -M main
  cp -R "$ROOT/bin/." "$fixture/bin/"
  chmod 700 "$fixture/bin"/*.sh "$fixture/bin"/*.py
  cat > "$fixture/test-bin/od" <<SH
#!/usr/bin/env bash
if [ "\${3:-}" = 48 ]; then
  owner=\${FM_TEST_ROOT_GENERATION_OWNER:-unknown}
  counter_lock="$fixture/root-generation-counter.lock"
  while ! mkdir "\$counter_lock" 2>/dev/null; do sleep 0.001; done
  owner_calls="$fixture/root-generation-calls-\$owner"
  owner_count=\$(cat "\$owner_calls" 2>/dev/null || printf 0)
  owner_count=\$((owner_count + 1))
  printf '%s\n' "\$owner_count" > "\$owner_calls"
  random_calls=\$(cat "$fixture/random-48-calls" 2>/dev/null || printf 0)
  random_calls=\$((random_calls + 1))
  printf '%s\n' "\$random_calls" > "$fixture/random-48-calls"
  root_generations=\$(cat "$fixture/root-generation-count" 2>/dev/null || printf 0)
  if [ "\$owner_count" -le 2 ]; then
    root_key_calls=\$(cat "$fixture/root-key-count" 2>/dev/null || printf 0)
    root_key_calls=\$((root_key_calls + 1))
    printf '%s\n' "\$root_key_calls" > "$fixture/root-key-count"
  fi
  if [ "\$owner_count" -eq 1 ]; then
    root_generations=\$((root_generations + 1))
    printf '%s\n' "\$root_generations" > "$fixture/root-generation-count"
    if [ ! -e "$fixture/root-generation-started" ]; then
      : > "$fixture/root-generation-started"
      wait_for_release=1
    fi
  fi
  rmdir "\$counter_lock"
  if [ "\${wait_for_release:-0}" -eq 1 ]; then
    while [ ! -e "$fixture/allow-root-generation" ]; do sleep 0.02; done
  fi
fi
case "\${3:-}" in
  48) printf '%096d\n' 0 | tr 0 a ;;
  *) exec /usr/bin/od "\$@" ;;
esac
SH
  chmod 700 "$fixture/test-bin/od"
  first_output="$fixture/first.log"
  second_output="$fixture/second.log"
  (
    cd "$fixture" || exit 1
    exec 9<&- 18<&- 2>/dev/null || true
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" \
      FM_STATE_OVERRIDE="$fixture/state" \
      FM_TEST_ROOT_GENERATION_OWNER=first \
      PATH="$fixture/test-bin:$PATH" \
      exec "$fixture/bin/fm-session-authority-exec.sh" bash -c ':'
  ) >"$first_output" 2>&1 &
  first_pid=$!
  (
    cd "$fixture" || exit 1
    exec 9<&- 18<&- 2>/dev/null || true
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" \
      FM_STATE_OVERRIDE="$fixture/state" \
      FM_TEST_ROOT_GENERATION_OWNER=second \
      PATH="$fixture/test-bin:$PATH" \
      exec "$fixture/bin/fm-session-authority-exec.sh" bash -c ':'
  ) >"$second_output" 2>&1 &
  second_pid=$!
  for _ in $(seq 1 250); do
    [ -f "$fixture/root-generation-started" ] && break
    sleep 0.02
  done
  [ -f "$fixture/root-generation-started" ] \
    || fail "concurrent cold-start fixture did not reach root generation"
  : > "$fixture/allow-root-generation"
  set +e
  for pid in "$first_pid" "$second_pid"; do
    attempts=0
    while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 600 ]; do
      sleep 0.02
      attempts=$((attempts + 1))
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid"
    status=$?
    if [ "$pid" = "$first_pid" ]; then
      first_status=$status
    else
      second_status=$status
    fi
  done
  set -e
  custodian_pid=$(sed -n '2s/^pid=//p' \
    "$fixture/state/.session-durable-authority" 2>/dev/null || true)
  case "$custodian_pid" in
    ''|*[!0-9]*) ;;
    *)
      kill "$custodian_pid" 2>/dev/null || true
      sleep 0.02
      kill -KILL "$custodian_pid" 2>/dev/null || true
      ;;
  esac
  winners=0
  [ "$first_status" -eq 0 ] && winners=$((winners + 1))
  [ "$second_status" -eq 0 ] && winners=$((winners + 1))
  [ "$winners" -eq 1 ] || {
    cat "$first_output" "$second_output" >&2
    fail "concurrent primary cold starts did not have exactly one winner"
  }
  [ -f "$fixture/state/.session-authority" ] \
    && [ -f "$fixture/state/.session-durable-authority" ] \
    || fail "cold-start winner did not publish one authenticated root"
  root_generations=$(cat "$fixture/root-generation-count" 2>/dev/null || true)
  [ "$root_generations" = 1 ] \
    || fail "concurrent cold starts generated multiple roots"
  root_key_calls=$(cat "$fixture/root-key-count" 2>/dev/null || true)
  [ "$root_key_calls" = 2 ] \
    || fail "cold-start root key generation was repeated"
  random_calls=$(cat "$fixture/random-48-calls" 2>/dev/null || true)
  [ "$random_calls" = 3 ] \
    || fail "cold-start root generation was not serialized before admission"
  pass "concurrent cold starts serialize root provisioning"
}

test_concurrent_broker_start_has_one_publisher() {
  local fixture first_output second_output first_pid second_pid
  local broker_pids broker_count record_pid
  local request_one_pid request_two_pid ready_one ready_two release_one release_two
  local start_ready_one start_ready_two start_release_one start_release_two
  local start_ack_capture start_ack_result_one start_ack_result_two
  local start_ack_one start_ack_two
  local ack_capture_one ack_result winner_slot winner_ready release_path
  local first_output_capture second_output_capture
  local first_status_capture second_status_capture
  fixture=$(fm_test_tmproot fm-concurrent-broker-start)
  CONCURRENT_FIXTURE_STATE="$fixture/state"
  CONCURRENT_FIXTURE_ROOT="$fixture"
  CONCURRENT_PUBLISHED_BROKER_PID=
  mkdir -p "$fixture/bin" "$fixture/state"
  printf '%s\n' alpha > "$fixture/.fm-secondmate-home"
  FM_TEST_PRODUCTION_BROKER=1 prepare_launch "$fixture"
  cp "$ROOT/bin/fm-session-authority-broker.py" \
    "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-session-durable-authority.sh" \
    "$ROOT/bin/fm-worker-isolation-lib.sh" \
    "$ROOT/bin/fm-procargs-lib.sh" "$ROOT/bin/fm-wake-lib.sh" \
    "$fixture/bin/"
  chmod 700 "$fixture/bin"/*.sh "$fixture/bin/fm-session-authority-broker.py"
  first_output="$fixture/state/concurrent-broker-first"
  second_output="$fixture/state/concurrent-broker-second"
  start_ready_one="$fixture/state/.test-start-barrier-ready-1"
  start_ready_two="$fixture/state/.test-start-barrier-ready-2"
  start_release_one="$fixture/state/.test-start-barrier-release-1"
  start_release_two="$fixture/state/.test-start-barrier-release-2"
  start_ack_capture="$fixture/state/.test-start-barrier-ack"
  start_ack_result_one="$fixture/state/.test-start-barrier-result-1"
  start_ack_result_two="$fixture/state/.test-start-barrier-result-2"
  ready_one="$fixture/state/.test-supervisor-ready-1"
  ready_two="$fixture/state/.test-supervisor-ready-2"
  release_one="$fixture/state/.test-supervisor-release-1"
  release_two="$fixture/state/.test-supervisor-release-2"
  ack_capture_one="$fixture/state/.test-supervisor-ack-1"
  ack_result="$fixture/state/.test-supervisor-ack-result"
  first_output_capture="$first_output.capture"
  second_output_capture="$second_output.capture"
  first_status_capture="$first_output.status.capture"
  second_status_capture="$second_output.status.capture"
  rm -f "$start_ready_one" "$start_ready_two" \
    "$start_release_one" "$start_release_two" "$start_ack_capture" \
    "$start_ack_result_one" "$start_ack_result_two" \
    "$ready_one" "$ready_two" "$release_one" \
    "$release_two" "$ack_capture_one" "$ack_result" "$first_output" \
    "$second_output" "$first_output.status" "$second_output.status" \
    "$first_output_capture" \
    "$second_output_capture" "$first_status_capture" "$second_status_capture"
  mkfifo "$start_ready_one" "$start_ready_two" \
    "$start_release_one" "$start_release_two" \
    "$start_ack_result_one" "$start_ack_result_two" \
    "$ready_one" "$ready_two" "$release_one" "$release_two" \
    "$ack_result" \
    "$first_output" "$second_output" "$first_output.status" \
    "$second_output.status"
  ( timeout 10 sh -c \
      'IFS= read -r value < "$1" && printf "%s|%s\n" "$2" "$value" > "$3"' \
      read-start-barrier-1 "$start_ready_one" 1 "$start_ack_result_one" ) &
  CONCURRENT_CALLER_READER_ONE=$!
  ( timeout 10 sh -c \
      'IFS= read -r value < "$1" && printf "%s|%s\n" "$2" "$value" > "$3"' \
      read-start-barrier-2 "$start_ready_two" 2 "$start_ack_result_two" ) &
  CONCURRENT_CALLER_READER_TWO=$!
  ( timeout 10 sh -c '
      exec 9< "$1" || exit 1
      IFS= read -r first <&9 || exit 1
      if IFS= read -r extra <&9; then exit 1; fi
      exec 9<&-
      exec 8< "$2" || exit 1
      IFS= read -r second <&8 || exit 1
      if IFS= read -r extra <&8; then exit 1; fi
      case "$first" in
        1\|CONTEND\ pid=*) first_pid=${first#*pid=} ;;
        *) exit 1 ;;
      esac
      case "$second" in
        2\|CONTEND\ pid=*) second_pid=${second#*pid=} ;;
        *) exit 1 ;;
      esac
      case "$first_pid" in ""|*[!0-9]*) exit 1 ;; esac
      case "$second_pid" in ""|*[!0-9]*) exit 1 ;; esac
      printf "%s\n%s\n" "$first" "$second" > "$3"
    ' collect-start-barriers "$start_ack_result_one" \
      "$start_ack_result_two" "$start_ack_capture" ) &
  CONCURRENT_START_ACK_COLLECTOR=$!
  ( timeout 10 sh -c \
      'IFS= read -r value < "$1" && printf "%s|%s\n" "$2" "$value" > "$3"' \
      read-supervisor-ready-1 "$ready_one" 1 "$ack_result" ) &
  CONCURRENT_ACK_READER_ONE=$!
  ( timeout 10 sh -c \
      'IFS= read -r value < "$1" && printf "%s|%s\n" "$2" "$value" > "$3"' \
      read-supervisor-ready-2 "$ready_two" 2 "$ack_result" ) &
  CONCURRENT_ACK_READER_TWO=$!
  ( timeout 10 sh -c \
      'IFS="|" read -r slot value < "$1" && printf "%s\n%s\n" "$slot" "$value" > "$2"' \
      collect-supervisor-ready "$ack_result" "$ack_capture_one" ) &
  CONCURRENT_ACK_COLLECTOR=$!
  ( timeout 10 cat "$first_output" > "$first_output_capture" ) &
  CONCURRENT_OUTPUT_READER_ONE=$!
  ( timeout 10 cat "$second_output" > "$second_output_capture" ) &
  CONCURRENT_OUTPUT_READER_TWO=$!
  ( timeout 10 cat "$first_output.status" > "$first_status_capture" ) &
  CONCURRENT_STATUS_READER_ONE=$!
  ( timeout 10 cat "$second_output.status" > "$second_status_capture" ) &
  CONCURRENT_STATUS_READER_TWO=$!
  ( timeout 10 sh -c 'printf "%s\n" "$1" > "$2"' \
      send-first-broker-request \
      "broker|secondmate|$fixture|$first_output|1" "$REQUEST_FIFO" ) &
  request_one_pid=$!
  CONCURRENT_REQUEST_ONE=$request_one_pid
  ( timeout 10 sh -c 'printf "%s\n" "$1" > "$2"' \
      send-second-broker-request \
      "broker|secondmate|$fixture|$second_output|2" "$REQUEST_FIFO" ) &
  request_two_pid=$!
  CONCURRENT_REQUEST_TWO=$request_two_pid
  wait "$request_one_pid" \
    || fail "first concurrent broker request was not accepted"
  wait "$request_two_pid" \
    || fail "second concurrent broker request was not accepted"
  CONCURRENT_REQUEST_ONE=
  CONCURRENT_REQUEST_TWO=
  wait "$CONCURRENT_CALLER_READER_ONE" \
    || fail "first broker caller did not reach recovery-lock contention"
  wait "$CONCURRENT_CALLER_READER_TWO" \
    || fail "second broker caller did not reach recovery-lock contention"
  CONCURRENT_CALLER_READER_ONE=
  CONCURRENT_CALLER_READER_TWO=
  wait "$CONCURRENT_START_ACK_COLLECTOR" \
    || fail "concurrent callers did not reach recovery-lock contention"
  CONCURRENT_START_ACK_COLLECTOR=
  start_ack_one=$(sed -n '1p' "$start_ack_capture")
  start_ack_two=$(sed -n '2p' "$start_ack_capture")
  case "$start_ack_one" in
    1\|CONTEND\ pid=[0-9]*) ;;
    *) fail "first caller did not acknowledge recovery-lock contention" ;;
  esac
  case "$start_ack_two" in
    2\|CONTEND\ pid=[0-9]*) ;;
    *) fail "second caller did not acknowledge recovery-lock contention" ;;
  esac
  ( timeout 10 sh -c 'printf "GO\n" > "$1"' \
      release-start-barrier-1 "$start_release_one" ) &
  CONCURRENT_RELEASE_WRITER_ONE=$!
  ( timeout 10 sh -c 'printf "GO\n" > "$1"' \
      release-start-barrier-2 "$start_release_two" ) &
  CONCURRENT_RELEASE_WRITER_TWO=$!
  wait "$CONCURRENT_RELEASE_WRITER_ONE" \
    || fail "first recovery-lock barrier release was not delivered"
  wait "$CONCURRENT_RELEASE_WRITER_TWO" \
    || fail "second recovery-lock barrier release was not delivered"
  CONCURRENT_RELEASE_WRITER_ONE=
  CONCURRENT_RELEASE_WRITER_TWO=
  winner_slot=$(sed -n '1p' "$ack_capture_one")
  winner_ready=$(sed -n '2p' "$ack_capture_one")
  case "$winner_slot" in
    1)
      wait "$CONCURRENT_ACK_READER_ONE" \
        || fail "first production supervisor acknowledgment failed"
      kill_owned_process_tree "$CONCURRENT_ACK_READER_TWO"
      ;;
    2)
      wait "$CONCURRENT_ACK_READER_TWO" \
        || fail "second production supervisor acknowledgment failed"
      kill_owned_process_tree "$CONCURRENT_ACK_READER_ONE"
      ;;
    *) fail "supervisor barrier acknowledgment named an invalid caller" ;;
  esac
  CONCURRENT_ACK_READER_ONE=
  CONCURRENT_ACK_READER_TWO=
  case "$winner_ready" in
    READY\ pid=[0-9]*) ;;
    *) fail "supervisor barrier acknowledgment was malformed" ;;
  esac
  [ ! -e "$fixture/state/.session-authority-broker" ] \
    || fail "broker published before supervisor release"
  case "$winner_slot" in
    1) release_path=$release_one ;;
    2) release_path=$release_two ;;
  esac
  timeout 10 sh -c 'printf "GO\\n" > "$1"' release-supervisor "$release_path" \
    || fail "supervisor release was not delivered"
  wait "$CONCURRENT_OUTPUT_READER_ONE" \
    || fail "first broker caller did not return"
  wait "$CONCURRENT_OUTPUT_READER_TWO" \
    || fail "second broker caller did not return"
  wait "$CONCURRENT_STATUS_READER_ONE" \
    || fail "first broker caller status was not published"
  wait "$CONCURRENT_STATUS_READER_TWO" \
    || fail "second broker caller status was not published"
  CONCURRENT_OUTPUT_READER_ONE=
  CONCURRENT_OUTPUT_READER_TWO=
  CONCURRENT_STATUS_READER_ONE=
  CONCURRENT_STATUS_READER_TWO=
  [ "$(cat "$first_status_capture")" = 0 ] \
    && [ "$(cat "$second_status_capture")" = 0 ] \
    || fail "a concurrent broker loser did not join the published broker"
  first_pid=$(cat "$first_output_capture")
  second_pid=$(cat "$second_output_capture")
  case "$first_pid:$second_pid" in
    ''|*[!0-9:]*) fail "concurrent broker callers returned malformed pids" ;;
  esac
  [ "$first_pid" = "$second_pid" ] \
    || fail "concurrent broker callers did not join one broker"
  record_pid=$(sed -n '2s/^pid=//p' \
    "$fixture/state/.session-authority-broker")
  [ "$record_pid" = "$first_pid" ] \
    || fail "broker record did not bind to the shared production broker"
  kill -0 "$record_pid" 2>/dev/null \
    || fail "published production broker exited early"
  broker_pids=$(ps -eo pid=,args= | awk \
    -v script="$fixture/bin/fm-session-authority-broker.py" \
    -v state="$fixture/state" \
    '$0 ~ script && $0 ~ state && $0 ~ / --state / {print $1}')
  broker_count=$(printf '%s\n' "$broker_pids" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$broker_count" -eq 1 ] \
    || fail "production recovery lock published competing brokers"
  CONCURRENT_PUBLISHED_BROKER_PID=$record_pid
  reap_concurrent_broker
  terminate_owned_process "$LAUNCH_PID"
  BROKER_PID=
  LAUNCH_PID=
  CONCURRENT_FIXTURE_STATE=
  CONCURRENT_FIXTURE_ROOT=
  pass "concurrent broker callers publish one production generation"
}

test_transaction_authority_and_arbitration_controls() {
  local lock_source broker_source
  lock_source=$(cat "$ROOT/bin/fm-session-lock-lib.sh")
  broker_source=$(cat "$ROOT/bin/fm-session-authority-broker.py")
  [[ "$lock_source" == *"version=5"* ]] \
    || fail "transaction manifest lost its authenticated generation version"
  [[ "$lock_source" == *"fm_session_authority_transaction_hmac"* ]] \
    || fail "transaction manifest is not rooted in durable authority"
  [[ "$lock_source" == *"fm_session_authority_admission_lease_valid"* ]] \
    || fail "transaction transitions are not lease-bound"
  [[ "$lock_source" == *"fm_session_authority_transaction_remove"* ]] \
    || fail "transaction cleanup is not bounded to authenticated entries"
  [[ "$lock_source" == *'rmdir -- "$txn"'* ]] \
    || fail "transaction cleanup does not reject unexpected entries"
  [[ "$lock_source" != *'.session-authority-rotation.lock"'* ]] \
    || fail "rotation retained a caller-precreatable path mutex"
  [[ "$broker_source" == *"os.O_NOFOLLOW"* ]] \
    || fail "authority startup arbitration does not reject symlinked lock paths"
  [[ "$broker_source" == *"rename_noreplace"* ]] \
    || fail "authority lock publication is not atomic"
  [[ "$broker_source" == *"tempfile.mkstemp"* ]] \
    || fail "authority lock publication is not staged privately"
  [[ "$broker_source" != *"open_authority_anonymous_lock"* ]] \
    || fail "broker admission retains a per-call lock capability"
  [[ "$broker_source" != *"os.O_TMPFILE"* ]] \
    || fail "broker admission retains unrelated anonymous lock state"
  [[ "$broker_source" == *'kind not in (b"L", b"D", b"K", b"R")'* ]] \
    || fail "broker lease control channel is missing"
  [[ "$broker_source" == *"threading.Thread"* ]] \
    || fail "broker admission control blocks its request loop"
  [[ "$broker_source" == *"trusted_wrapper_ancestor"* ]] \
    || fail "broker admission is not bound to wrapper provenance"
  [[ "$broker_source" == *"--capability-fd"* ]] \
    || fail "broker admission lacks a protected wrapper capability"
  [[ "$broker_source" == *"--caller-start"* ]] \
    || fail "primary admission lacks caller-generation binding"
  pass "transaction and arbitration controls retain authenticated ownership"
}

test_lock_rejects_ready_transaction_before_recovery() {
  local fixture state rc
  fixture=$(fm_test_tmproot fm-lock-ready-gate)
  state="$fixture/state"
  mkdir -p "$state/.session-authority-transaction"
  printf 'ready\n' > "$state/.session-authority-transaction/ready"
  set +e
  (
    cd "$fixture" || exit 1
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
      FM_AGENT_ROLE=secondmate FM_AGENT_TASK=ready-gate \
      FM_AGENT_OWNER_HOME="$fixture" "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1
  )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unproven ready transaction reached session authority recovery"
  [ -f "$state/.session-authority-transaction/ready" ] \
    || fail "pre-recovery isolation refusal did not preserve ready evidence"
  pass "session lock enforces isolation before ready transaction recovery"
}

test_primary_bootstrap_cleans_partial_live_binding() {
  local fixture state fakebin rc target
  fixture=$(fm_test_tmproot fm-primary-bootstrap-atomic)
  state="$fixture/home/state"
  fakebin="$fixture/fakebin"
  mkdir -p "$state" "$fakebin"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
target=${!#}
if [ "$target" = "$FM_TEST_BOOTSTRAP_LIVE" ]; then
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  set +e
  (
    cd "$ROOT" || exit 1
    FM_HOME="$ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
      FM_TEST_BOOTSTRAP_LIVE="$state/.session-authority-live" \
      PATH="$fakebin:$PATH" \
      "$ROOT/bin/fm-session-authority-exec.sh" bash -c ':'
  ) >"$fixture/stdout" 2>"$fixture/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "bootstrap succeeded after live binding commit failure"
  for target in .primary-checkout .lock .session-authority .session-authority-live; do
    [ ! -e "$state/$target" ] && [ ! -L "$state/$target" ] \
      || fail "partial bootstrap state survived for $target"
  done
  pass "primary bootstrap removes partial ownership after live binding failure"
}

test_receipt_backed_synthetic_census() {
  local fixture home state task pid start identity receipt index
  fixture=$(fm_test_tmproot fm-receipt-census)
  home="$fixture/home"
  state="$home/state"
  task=receipt-census-task
  mkdir -p "$state"
  (
    cd "$home" || exit 1
    exec 18< <(while :; do printf '%s\n' \
      0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef; done)
    export FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      FM_SESSION_AUTHORITY_DURABLE_FD=18
    . "$ROOT/bin/fm-agent-cwd-lib.sh"
    (
      cd "$home" || exit 1
      exec env FM_AGENT_TASK="$task" FM_AGENT_OWNER_HOME="$home" \
        FM_AGENT_ROLE=secondmate sleep 60
    ) &
    pid=$!
    start=$(fm_session_process_start "$pid") || exit 1
    identity=$(fm_session_process_identity "$pid") || exit 1
    receipt="$state/.secondmate-launch-receipts/$task"
    mkdir -p "${receipt%/*}" || exit 1
    fm_session_launch_receipt_write \
      "$receipt" "$task" "$home" "$pid" "$start" "$identity" || exit 1
    index=$(fm_agent_task_pid_index) || exit 1
    printf '%s\n' "$index" | grep -F "$task	$home	secondmate	$pid" >/dev/null \
      || exit 1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  ) || fail "receipt-backed synthetic agent was not accepted by the census"
  pass "synthetic agent census requires a signed launch receipt"
}

if [ "${FM_SESSION_AUTHORITY_BROKER_FOCUS:-}" = review-fixes ]; then
  test_broker_client_deadline_is_behavioral
  test_inherited_capability_requires_anonymous_pipe
  test_primary_authority_record_and_live_descriptor_binding
  test_primary_wrapper_rotates_dead_authority
  test_transaction_authority_and_arbitration_controls
  test_lock_rejects_ready_transaction_before_recovery
  test_concurrent_primary_cold_start_has_one_winner
  test_primary_bootstrap_cleans_partial_live_binding
  test_receipt_backed_synthetic_census
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_watchdog", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

def unavailable(_pid):
    raise OSError("unreadable process identity")

broker.process_generation_for_recovery = unavailable
if broker.launch_process_state(42, "proc:start", "exe:identity", "/authority-exec.sh") != "unknown":
    raise SystemExit("watchdog treated inspection failure as process death")
PY
  then
    fail "broker watchdog did not retain an unknown launch state"
  fi
  pass "broker watchdog retains authority on launch inspection failure"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_proof", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

read_fd, write_fd = os.pipe()
try:
    os.write(write_fd, b"00" * 32 + b"\nZmFrZS1zaWduZWQtcmVjZWlwdA==\n")
finally:
    os.close(write_fd)
try:
    broker.read_launch_evidence(
        read_fd, home="/tmp/home", task="alpha",
        launch_script="/tmp/home/bin/fm-session-authority-exec.sh",
    )
except ValueError:
    pass
else:
    raise SystemExit("caller-supplied launch evidence bypassed enrollment proof")
finally:
    os.close(read_fd)
PY
  then
    fail "broker accepted self-signed launch evidence without enrollment proof"
  fi
  pass "broker rejects self-signed launch evidence without enrollment proof"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import hashlib
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_forged_chain", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    issuer = Path(temporary) / "issuer"
    home = Path(temporary) / "home"
    state = issuer / "state"
    home_state = home / "state"
    state.mkdir(parents=True)
    home_state.mkdir(parents=True)
    (home / ".fm-secondmate-home").write_text("alpha\n", encoding="utf-8")
    (state / ".lock").write_text("forged-owner\n", encoding="utf-8")
    checkout = broker_path.parent.parent.resolve()
    (state / ".primary-checkout").write_text(f"{checkout}\n", encoding="utf-8")
    current = os.getpid()
    start, identity = broker.process_generation(current)
    authority = state / ".session-authority"
    authority.write_text(
        "version=2\n"
        f"pid={current}\nstart={start}\nidentity={identity}\n"
        "token=" + "0" * 64 + "\nowner=forged-owner\n"
        f"home={issuer}\ncheckout={checkout}\n",
        encoding="utf-8",
    )
    authority.chmod(0o600)
    read_fd, write_fd = os.pipe()
    os.dup2(read_fd, 18)
    os.close(read_fd)
    os.write(write_fd, b"00" * 32 + b"\n")
    os.close(write_fd)
    authority_descriptor = os.readlink("/proc/self/fd/18")
    primary_root = home_state / ".session-primary-root"
    primary_root.write_text(
        "version=1\n"
        "task=alpha\n"
        f"home={home}\nprimary-home={issuer}\nprimary-checkout={checkout}\n"
        f"authority-pid={current}\nauthority-start={start}\n"
        f"authority-identity={identity}\nauthority-fd=18\n"
        f"authority-descriptor={authority_descriptor}\n"
        f"durable-descriptor={authority_descriptor}\n"
        f"authority-sha256={hashlib.sha256(authority.read_bytes()).hexdigest()}\n"
        f"authority-hmac={'0' * 64}\n",
        encoding="utf-8",
    )
    primary_root.chmod(0o600)
    authority_digest = hashlib.sha256(authority.read_bytes()).hexdigest()
    root_digest = hashlib.sha256(primary_root.read_bytes()).hexdigest()
    fields = {
        "version": "5", "role": "secondmate", "task": "alpha",
        "home": str(home), "issuer-home": str(issuer),
        "issuer-authority": authority_digest,
        "nonce": "a" * 64, "broker-pid": str(current),
        "broker-start": start, "broker-identity": identity,
        "broker-script": str(checkout / "bin" / "fm-session-authority-exec.sh"),
        "authority-fd": "18", "authority-descriptor": authority_descriptor,
        "signer-pid": str(current), "signer-start": start,
        "signer-identity": identity, "public-key": "ZmFrZQ==",
        "public-key-sha256": "0" * 64, "endpoint-pid": str(current),
        "endpoint-start": start, "endpoint-identity": identity,
        "primary-root-sha256": root_digest,
    }
    try:
        broker.verify_trusted_primary_authority(
            fields,
            home=fields["home"],
            launch_pid=current,
            launch_start=start,
            launch_identity=identity,
        )
    except ValueError as error:
        if str(error) != "untrusted primary root authentication":
            raise SystemExit(f"forged chain failed before root authentication: {error}")
    else:
        raise SystemExit("a complete forged enrollment chain was accepted")
PY
  then
    fail "broker accepted a complete forged enrollment chain"
  fi
  pass "broker rejects a complete forged enrollment chain"
  if FM_TEST_PROCESS=1 FM_TEST_AUTHORITY_BROKER_PID=$$ \
    bash -c '
      . "$1"
      fm_session_authority_capability_present
    ' _ "$ROOT/bin/fm-session-lock-lib.sh"; then
    fail "caller-controlled test authority reached the production capability seam"
  fi
  pass "caller-controlled test authority cannot reach production capability seam"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_task", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    state = Path(temporary) / "state"
    state.mkdir()
    record = state / ".session-authority-broker"
    home = Path(temporary)
    checkout = broker_path.parent.parent
    metadata = {
        "home": str(home),
        "checkout": str(checkout),
        "task": "foreign-task",
        "script": str(broker_path),
        "launch-script": str(home / "bin" / "fm-session-authority-exec.sh"),
    }
    broker.read_record_shape = lambda _path: metadata
    status = broker.recover_stale_locked(
        SimpleNamespace(
            record=str(record),
            state=str(state),
            home=str(home),
            checkout=str(checkout),
            task="requested-task",
            launch_script=metadata["launch-script"],
        ),
        launch_evidence=(b"key", 2, "proc:start", "exe:launch"),
    )
    if status != 1:
        raise SystemExit("stale recovery accepted a record for another task")
PY
  then
    fail "stale recovery did not bind the requested task identity"
  fi
  pass "stale recovery binds the requested task identity"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_direct_recovery", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    home = Path(temporary)
    state = home / "state"
    state.mkdir()
    record = state / ".session-authority-broker"
    record.write_text("record\n", encoding="utf-8")
    record.chmod(0o600)
    launch_script = home / "bin" / "fm-session-authority-exec.sh"
    metadata = {
        "version": "1",
        "pid": "2",
        "start": "proc:broker",
        "identity": "exe:broker",
        "socket": "abstract:broker",
        "home": str(home),
        "checkout": str(broker_path.parent.parent),
        "task": "task",
        "script": str(broker_path),
        "uid": str(os.geteuid()),
        "gid": str(os.getegid()),
        "launch-pid": str(os.getppid()),
        "launch-start": "proc:launch",
        "launch-identity": "exe:launch",
        "launch-script": str(launch_script),
    }
    broker.read_record_shape = lambda _path: metadata
    status = broker.recover_stale_locked(
        SimpleNamespace(
            record=str(record),
            state=str(state),
            home=str(home),
            checkout=str(broker_path.parent.parent),
            task="task",
            launch_script=str(launch_script),
        ),
        launch_evidence=(b"key", os.getppid(), "proc:launch", "exe:launch"),
    )
    if status != 1:
        raise SystemExit("direct stale recovery used a path-only fallback")
PY
  then
    fail "direct stale recovery did not fail closed without capability"
  fi
  pass "direct stale recovery fails closed without capability"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
source = broker_path.read_text(encoding="utf-8")
if any(
    marker in source
    for marker in (
        "connection_slots",
        "BoundedSemaphore",
        "lock_manager_peer_is_reserved",
        "MAX_LOCK_MANAGER_RESERVED_PENDING",
        "MAX_LOCK_MANAGER_UNAUTHENTICATED_PENDING",
        "lock_manager_serve",
        "socket.SOCK_DGRAM",
    )
):
    raise SystemExit("lock manager still exposes an unauthenticated queue")
cleanup = source[source.index("def cleanup_recovery_quarantines("):source.index("def unlink_owned_record(")]
if "AUTHORITY_SERIALIZATION_FD = 18" not in source:
    raise SystemExit("authority serialization did not use the inherited FD 18 capability")
if "def open_inherited_authority_record_lock(" not in source:
    raise SystemExit("authority serialization did not use an inherited capability")
if "def authority_admission_socket_name(" in source:
    raise SystemExit("authority serialization still derives authority from a socket name")
if "def acquire_authority_record_lock(" in source:
    raise SystemExit("path-based authority flock remains reachable")
if "def open_authority_admission_lock(" in source:
    raise SystemExit("visible authority lock publication remains reachable")
if ".glob(" in cleanup:
    raise SystemExit("quarantine cleanup still scans an attacker-controlled namespace")
handoff = source[source.index("def supervise("):source.index("def serve_locked(")]
if '"--record-lock-fd", str(AUTHORITY_SERIALIZATION_FD)' not in handoff:
    raise SystemExit("supervisor did not transfer the inherited serialization capability")
if "os.dup2(record_lock_fd.fileno()" in handoff or "record_lock_fd.close()" in handoff:
    raise SystemExit("supervisor replaced or closed the serialization capability before exec")
PY
  then
    fail "broker admission or lease handoff regressed"
  fi
  pass "broker admission and lease handoff retain authenticated ownership"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_recovery", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    home = Path(temporary)
    record = home / "state" / ".session-authority-broker"
    record.parent.mkdir()
    record.write_text("forged\n", encoding="utf-8")
    metadata = {
        "home": str(home),
        "checkout": "/forged/checkout",
        "script": "/forged/checkout/bin/fm-session-authority-broker.py",
        "launch-script": str(home / "bin" / "fm-session-authority-exec.sh"),
    }
    broker.read_record_shape = lambda _path: metadata
    broker.stop_recorded_broker = lambda *_args: (_ for _ in ()).throw(
        AssertionError("forged broker path reached termination")
    )
    status = broker.recover_stale(SimpleNamespace(record=str(record)))
    if status != 1 or not record.exists():
        raise SystemExit("recovery accepted mutable broker script metadata")
PY
  then
    fail "stale recovery did not bind termination to the current broker script"
  fi
  pass "stale recovery rejects forged broker checkout metadata"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_termination", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

generation = ("proc:broker", "exe:python")
broker.process_generation_for_recovery = lambda _pid: generation
broker.process_command = lambda _pid: [
    "python3",
    str(broker_path),
    "serve",
    "--state",
    "/other/state",
    "--home",
    "/other/home",
    "--checkout",
    str(broker_path.parent.parent),
    "--task",
    "other",
    "--launch-evidence-fd",
    "19",
    "--launch-script",
    "/other/home/bin/fm-session-authority-exec.sh",
]
if broker.stop_recorded_broker(
    42,
    generation,
    script=str(broker_path),
    state="/home/state",
    home="/home",
    checkout=str(broker_path.parent.parent),
    task="alpha",
    launch_script="/home/bin/fm-session-authority-exec.sh",
):
    raise SystemExit("termination accepted another home's broker argv")
PY
  then
    fail "broker termination did not validate the complete canonical argv"
  fi
  pass "stale recovery rejects another home's broker argv"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_unlink", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    record = Path(temporary) / "record"
    record.write_text("replacement\n", encoding="utf-8")
    original_stat = os.stat_result((0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    current_stat = record.lstat()
    if broker.unlink_owned_record(
        record,
        {},
        expected_stat=original_stat,
    ):
        raise SystemExit("inode mismatch removed a replacement record")
    if not record.exists() or current_stat.st_ino == original_stat.st_ino:
        raise SystemExit("inode replacement fixture was not distinct")
PY
  then
    fail "stale record deletion did not reject an inode replacement"
  fi
  pass "stale record deletion rejects inode replacement"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_quarantine", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    record = Path(temporary) / "record"
    metadata = {
        "version": "1",
        "pid": "2",
        "start": "proc:start",
        "identity": "exe:python",
        "socket": "abstract:record",
        "home": "/home",
        "checkout": "/checkout",
        "task": "task",
        "script": "/checkout/bin/fm-session-authority-broker.py",
        "uid": "0",
        "gid": "0",
        "launch-pid": "2",
        "launch-start": "proc:launch",
        "launch-identity": "exe:python",
        "launch-script": "/home/bin/fm-session-authority-exec.sh",
    }
    record.write_text(
        "".join(f"{key}={value}\n" for key, value in metadata.items()),
        encoding="utf-8",
    )
    record.chmod(0o600)
    original_stat = record.lstat()
    if not broker.unlink_owned_record(
        record,
        metadata,
        expected_stat=original_stat,
        quarantine_key=b"review-quarantine-key",
    ):
        raise SystemExit("owned record was not quarantined")
    if record.exists():
        raise SystemExit("owned record pathname remained after quarantine")
    quarantines = [
        broker.quarantine_slot_path(record, b"review-quarantine-key", slot)
        for slot in range(broker.MAX_RECOVERY_QUARANTINES)
        if broker.quarantine_slot_path(
            record, b"review-quarantine-key", slot
        ).exists()
    ]
    if len(quarantines) != 1 or quarantines[0].lstat().st_ino != original_stat.st_ino:
        raise SystemExit("owned record inode was not retained atomically")
    if not broker.cleanup_recovery_quarantines(
        record,
        {
            "home": "/home",
            "checkout": "/checkout",
            "task": "task",
            "script": "/checkout/bin/fm-session-authority-broker.py",
            "launch-script": "/home/bin/fm-session-authority-exec.sh",
            "uid": "0",
            "gid": "0",
        },
        b"review-quarantine-key",
    ):
        raise SystemExit("owned record quarantine cleanup failed")
    if any(
        broker.quarantine_slot_path(record, b"review-quarantine-key", slot).exists()
        for slot in range(broker.MAX_RECOVERY_QUARANTINES)
    ):
        raise SystemExit("owned record quarantine was not reclaimed")
    forged = record.parent / f".{record.name}.recovery-forged"
    forged.write_text("forged\n", encoding="utf-8")
    forged.chmod(0o600)
    if not broker.cleanup_recovery_quarantines(
        record,
        {"home": "/home"},
        b"review-quarantine-key",
    ) or not forged.exists():
        raise SystemExit("unproven quarantine was removed")
    forged.unlink()
    proof_only = broker.quarantine_slot_path(
        record, b"review-quarantine-key", 0
    )
    proof_only.write_text("old\n", encoding="utf-8")
    proof_only_marker = proof_only.with_name(
        proof_only.name + broker.QUARANTINE_PROOF_SUFFIX
    )
    os.link(proof_only, proof_only_marker)
    proof_only.unlink()
    record.write_text("replacement\n", encoding="utf-8")
    if not broker.cleanup_recovery_quarantines(
        record,
        {"home": "/home"},
        b"review-quarantine-key",
    ) or proof_only_marker.exists() or not record.exists():
        raise SystemExit("proof-only quarantine was not recovered safely")
    for index in range(broker.MAX_RECOVERY_QUARANTINES + 1):
        forged_marker = record.parent / f".{record.name}.recovery-forged-{index}"
        forged_marker.write_text("forged\n", encoding="utf-8")
        if index == 0:
            forged_marker.with_name(
                forged_marker.name + broker.QUARANTINE_RECEIPT_SUFFIX
            ).write_text("forged\n", encoding="utf-8")
    if not broker.cleanup_recovery_quarantines(
        record,
        {"home": "/home"},
        b"review-quarantine-key",
    ):
        raise SystemExit("untrusted quarantine names exhausted recovery")
PY
  then
    fail "stale record deletion did not use atomic quarantine"
  fi
  pass "stale record deletion uses atomic quarantine"
if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import sys
import time
from multiprocessing import Process
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_lock", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    home = Path(temporary)
    state = home / "state"
    (home / "bin").mkdir(parents=True)
    state.mkdir()
    script = home / "bin" / "fm-session-authority-exec.sh"
    script.write_text("", encoding="utf-8")
    ready = state / "ready"
    release = state / "release"
    result = state / "result"
    read_fd, write_fd = os.pipe()
    os.write(write_fd, b"a" * 96 + b"\n")
    os.close(write_fd)

    def hold_lock():
        lock = broker.open_inherited_authority_record_lock(read_fd, blocking=False)
        if lock is None:
            raise SystemExit("inherited admission capability did not validate")
        ready.write_text("ready", encoding="utf-8")
        while not release.exists():
            time.sleep(0.01)
        broker.close_record_lock(lock)

    holder = Process(target=hold_lock)
    holder.start()
    deadline = time.monotonic() + 2
    while not ready.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not ready.exists():
        holder.terminate()
        holder.join()
        raise SystemExit("inherited admission holder did not start")

    def contend():
        lock = broker.open_inherited_authority_record_lock(read_fd, blocking=False)
        result.write_text("busy" if lock is None else "forged", encoding="utf-8")
        if lock is not None:
            broker.close_record_lock(lock)

    contender = Process(target=contend)
    contender.start()
    contender.join(2)
    release.write_text("release", encoding="utf-8")
    holder.join(2)
    if contender.exitcode != 0 or holder.exitcode != 0 or result.read_text() != "busy":
        raise SystemExit("an inherited admission capability was replayed")

    read_fd, write_fd = os.pipe()
    os.close(write_fd)
    try:
        if read_fd != broker.AUTHORITY_SERIALIZATION_FD:
            os.dup2(read_fd, broker.AUTHORITY_SERIALIZATION_FD)
            os.close(read_fd)
        if broker.inherited_authority_record_lock(
            broker.AUTHORITY_SERIALIZATION_FD,
            home=str(home), task="alpha", launch_script=str(script),
            launch_evidence=(b"k" * 32, 2, "s", "i")
        ) is not None:
            raise SystemExit("empty inherited capability was accepted as admission authority")
    finally:
        try:
            os.close(broker.AUTHORITY_SERIALIZATION_FD)
        except OSError:
            pass
PY
then
    fail "per-home serialization did not use a shared protected capability"
  fi
  pass "per-home serialization uses a shared protected capability and rejects forged pipes"
  FM_SESSION_AUTHORITY_BROKER_FOCUS=review-fixes-integration \
    "$0" || fail "production-equivalent broker review-fix tests failed"
  echo "# focused broker review-fix tests passed"
  exit 0
fi

prepare_launch() {
  local home=$1 provision_primary=${2:-0} launch_script real_exec
  local production_broker=${FM_TEST_PRODUCTION_BROKER:-0}
  local launch_start launch_identity receipt_body receipt_hmac nonce
  local issuer signer_private signer_public signer_public_b64 signer_digest
  local consumer_key consumer_public consumer_public_b64 consumer_digest
  local accepted_body accepted_digest final_body final_signature
  local primary_fixture primary_pid_file
  local primary_harness_pid
  local signer_output enrollment random_bin attempts=0
  local primary_setup_pid= rotation_key= owner_pid=
  local quoted_home quoted_issuer
  nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  launch_script="$home/bin/fm-session-authority-exec.sh"
  [ -z "$LAUNCH_PID" ] || kill "$LAUNCH_PID" 2>/dev/null || true
  [ -z "$LAUNCH_PID" ] || wait "$LAUNCH_PID" 2>/dev/null || true
  [ -z "$SIGNER_PID" ] || kill "$SIGNER_PID" 2>/dev/null || true
  [ -z "$SIGNER_PID" ] || wait "$SIGNER_PID" 2>/dev/null || true
  [ -z "$PRIMARY_PID" ] || kill "$PRIMARY_PID" 2>/dev/null || true
  [ -z "$PRIMARY_PID" ] || wait "$PRIMARY_PID" 2>/dev/null || true
  [ -z "$PRIMARY_HARNESS_PID" ] || kill "$PRIMARY_HARNESS_PID" 2>/dev/null || true
  [ -z "$PRIMARY_HARNESS_PID" ] || wait "$PRIMARY_HARNESS_PID" 2>/dev/null || true
  REQUEST_FIFO="$TMP_ROOT/requests-$REQUEST_SEQUENCE"
  PRIMARY_REQUEST_FIFO="$TMP_ROOT/primary-requests-$REQUEST_SEQUENCE"
  REQUEST_SEQUENCE=$((REQUEST_SEQUENCE + 1))
  issuer="$TMP_ROOT/issuer-$REQUEST_SEQUENCE"
  primary_fixture="$issuer/primary-fixture.sh"
  primary_pid_file="$issuer/primary.pid"
  real_exec="$home/bin/.fm-real-session-authority-exec.sh"
  mkdir -p "$home/bin" "$home/state"
  printf '%s\n' alpha > "$home/.fm-secondmate-home"
  if [ "$provision_primary" = 1 ]; then
    sleep 2
    fm_git_init_commit "$home"
    random_bin="$home/test-bin"
    mkdir -p "$random_bin"
    cat > "$random_bin/od" <<'SH'
#!/usr/bin/env bash
case "${3:-}" in
  48) printf '%096d\n' 0 | tr 0 a ;;
  32) printf '%064d\n' 0 | tr 0 a ;;
  *) exec /usr/bin/od "$@" ;;
esac
SH
    chmod 700 "$random_bin/od"
    cp "$ROOT"/bin/*.sh "$home/bin/"
    cp "$ROOT/bin/fm-session-authority-broker.py" "$home/bin/"
    chmod 700 "$home/bin"/*.sh "$home/bin/fm-session-authority-broker.py"
    cp "$home/bin/fm-session-authority-exec.sh" \
      "$home/bin/.fm-real-session-authority-exec.sh"
    (
      cd "$home" || exit 1
      exec env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
        PATH="$random_bin:$PATH" \
        "$home/bin/fm-session-authority-exec.sh" \
        bash -c 'while :; do sleep 60; done'
    ) >/dev/null 2>&1 &
    primary_setup_pid=$!
    ROTATION_PRIMARY_SETUP_PID=$primary_setup_pid
    attempts=0
    while [ "$attempts" -lt 250 ] \
      && { [ ! -f "$home/state/.session-authority" ] \
        || [ ! -f "$home/state/.session-durable-authority" ]; }; do
      sleep 0.02
      attempts=$((attempts + 1))
    done
    [ -f "$home/state/.session-authority" ] \
      && [ -f "$home/state/.session-durable-authority" ] \
      || fail "production primary fixture did not provision durable authority"
    ROTATION_CUSTODIAN_PID=$(sed -n '2s/^pid=//p' \
      "$home/state/.session-durable-authority")
    rotation_key=$(printf '%096d' 0 | tr 0 a)
    ROTATION_DURABLE_KEY=$rotation_key
    kill "$primary_setup_pid" 2>/dev/null || true
    wait "$primary_setup_pid" 2>/dev/null || true
    ROTATION_PRIMARY_SETUP_PID=
    owner_pid=$(sed -n '2s/^pid=//p' "$home/state/.session-authority")
    kill -0 "$owner_pid" 2>/dev/null \
      && fail "production primary fixture remained live after teardown"
  fi
  mkdir -p "$issuer/state"
  random_bin="$issuer/test-bin"
  mkdir -p "$random_bin"
  cat > "$random_bin/od" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = -N ] && [ "\${3:-}" = 32 ]; then
  printf '%s\\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
else
  exec /usr/bin/od "\$@"
fi
SH
  chmod 700 "$random_bin/od"
  rm -f "$REQUEST_FIFO"
  rm -f "$PRIMARY_REQUEST_FIFO"
  mkfifo "$REQUEST_FIFO" "$PRIMARY_REQUEST_FIFO"
  rm -f "$home/state/.test-admission-release"
  rm -f "$home/state/.test-admission-release-1" \
    "$home/state/.test-admission-release-2" \
    "$home/state/.test-admission-release-replay"
  mkfifo "$home/state/.test-admission-release" \
    "$home/state/.test-admission-release-1" \
    "$home/state/.test-admission-release-2" \
    "$home/state/.test-admission-release-replay"
  mkdir -p "$issuer/bin"
  cp "$ROOT/bin/fm-session-authority-exec.sh" \
    "$ROOT/bin/fm-session-enrollment-signer.sh" \
    "$ROOT/bin/fm-session-authority-broker.py" \
    "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-session-durable-authority.sh" \
    "$ROOT/bin/fm-worker-isolation-lib.sh" \
    "$ROOT/bin/fm-procargs-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$issuer/bin/"
  chmod 700 "$issuer/bin"/*.sh
  sleep 2
  fm_git_init_commit "$issuer"
  printf -v quoted_home '%q' "$home"
  printf -v quoted_issuer '%q' "$issuer"
  awk -v home="$quoted_home" -v issuer="$quoted_issuer" '
    /^fm_session_authority_admission_release \|\| \{/ {
      print "fm_session_primary_root_write alpha " home " " issuer " " issuer " bootstrap || exit 1"
    }
    { print }
  ' "$issuer/bin/fm-session-authority-exec.sh" \
    > "$issuer/bin/.fm-session-authority-exec.sh.tmp"
  chmod 700 "$issuer/bin/.fm-session-authority-exec.sh.tmp"
  mv "$issuer/bin/.fm-session-authority-exec.sh.tmp" \
    "$issuer/bin/fm-session-authority-exec.sh"
cat > "$launch_script" <<SH
#!/usr/bin/env bash
set -u
production_broker=$production_broker
broker_evidence_slot=0
while :; do
  exec 7< "$REQUEST_FIFO"
  while IFS='|' read -r kind role request_home output slot <&7; do
    [ -n "\$output" ] || continue
    status=0
    case "\$kind" in
      broker)
        if [ "\$production_broker" = 1 ]; then
          (
            status=0
            case "\$slot" in
              1|2) ;;
              *) status=1 ;;
            esac
            cd "\$request_home" || status=1
            if [ "\$status" -eq 0 ]; then
              exec 24> "\$request_home/state/.test-start-barrier-ready-\$slot" \
                || status=1
              exec 25<> "\$request_home/state/.test-start-barrier-release-\$slot" \
                || status=1
            fi
            if [ "\$status" -eq 0 ]; then
              exec 22> "\$request_home/state/.test-supervisor-ready-\$slot"
              exec 23<> "\$request_home/state/.test-supervisor-release-\$slot"
              export FM_HOME="\$request_home" \
                FM_ROOT_OVERRIDE="\$request_home" \
                FM_STATE_OVERRIDE="\$request_home/state" \
                FM_AGENT_ROLE=secondmate FM_AGENT_TASK=alpha \
                FM_AGENT_OWNER_HOME="\$request_home" \
                FM_SESSION_AUTHORITY_WRAPPER_AUTHORIZED=1 \
                FM_SESSION_AUTHORITY_START_BARRIER_READY_FD=24 \
                FM_SESSION_AUTHORITY_START_BARRIER_RELEASE_FD=25 \
                FM_SESSION_ENROLLMENT_NONCE=\$(sed -n '7s/^nonce=//p' \
                  "\$request_home/state/.session-authority-enrollment") \
                FM_SESSION_AUTHORITY_BARRIER_READY_FD=22 \
                FM_SESSION_AUTHORITY_BARRIER_RELEASE_FD=23 \
                enrollment_trusted_ticket_data=\$(openssl base64 -A < \
                  "\$request_home/state/.session-authority-enrollment") \
                enrollment_trusted_acceptance_data=\$(openssl base64 -A < \
                  "\$request_home/state/.session-authority-enrollment.accepted") \
                enrollment_trusted_consumer_key=\$(cat \
                  "\$request_home/state/.test-consumer-public")
              . "\$request_home/bin/fm-session-lock-lib.sh" || status=1
              if [ "\$status" -eq 0 ] \
                && fm_session_authority_socket_broker_start \
                  "\$request_home/state" "\$request_home" \
                  "\$request_home" alpha; then
                sed -n '2s/^pid=//p' \
                  "\$request_home/state/.session-authority-broker" \
                  > "\$output"
              else
                status=1
              fi
            fi
            printf '%s\n' "\$status" > "\$output.status"
            exec 24>&-
            exec 25<&-
            exec 22>&-
            exec 23<&-
          ) &
          continue
        fi
        cd "\$request_home" || status=1
        if [ "\$status" -eq 0 ]; then
          barrier_args=()
          evidence_path="\$request_home/state/.test-launch-evidence"
          if [ -e "\$request_home/state/.test-launch-evidence-1" ]; then
            broker_evidence_slot=\$((broker_evidence_slot + 1))
            evidence_path="\$request_home/state/.test-launch-evidence-\$broker_evidence_slot"
            exec 22> "\$request_home/state/.test-supervisor-ready-\$broker_evidence_slot"
            exec 23<> "\$request_home/state/.test-supervisor-release-\$broker_evidence_slot"
            barrier_args=(--barrier-ready-fd 22 --barrier-release-fd 23)
          fi
          exec 19< "\$evidence_path"
          if ! ( : <&18 ) 2>/dev/null && ! ( : >&18 ) 2>/dev/null; then
            exec 18< <(while :; do printf '%s\n' "$nonce"; done)
          fi
          exec 20< <(printf '%s\n' "$nonce")
          python3 "$BROKER" supervise --state "\$request_home/state" \\
            --home "\$request_home" --checkout "$ROOT" --task alpha \\
            --launch-evidence-fd 19 \\
            --launch-script "$launch_script" --record-lock-fd 20 \\
            "\${barrier_args[@]}" \\
            >/dev/null 2>&1 &
          broker_pid=\$!
          exec 19<&-
          exec 20<&-
          if [ "\${#barrier_args[@]}" -gt 0 ]; then
            exec 22>&-
            exec 23<&-
          fi
          printf '%s\n' "\$broker_pid" >"\$output"
        fi
        ;;
      admission)
        cd "\$request_home" || status=1
        if [ "\$status" -eq 0 ]; then
          exec 24<> "\$request_home/state/.test-admission-release" \
            || status=1
        fi
        if [ "\$status" -eq 0 ]; then
          exec 21< <(printf '%s\n' "$nonce")
          python3 "$BROKER" lock-holder --record "$RECORD" --capability-fd 21 \
            <&24 \
            >"\$output" 2>&1 &
          holder_pid=\$!
          attempts=0
          while [ "\$attempts" -lt 100 ] && ! grep -F 'LOCKED' "\$output" >/dev/null 2>&1; do
            if ! kill -0 "\$holder_pid" 2>/dev/null; then
              break
            fi
            sleep 0.02
            attempts=\$((attempts + 1))
          done
          if grep -F 'LOCKED' "\$output" >/dev/null 2>&1; then
            printf 'fixed-public-test-body' | env \
              FM_AGENT_ROLE=secondmate FM_AGENT_TASK=alpha \
              FM_AGENT_OWNER_HOME="\$request_home" \
              python3 "$BROKER" client --record "$RECORD" --kind live \
              >"\$output.probe" 2>&1
            printf '%s\n' "\$?" >"\$output.probe.status"
          else
            kill "\$holder_pid" 2>/dev/null || true
            status=1
          fi
          wait "\$holder_pid" || status=1
          exec 21<&-
          exec 24>&-
        fi
        ;;
      admission-replay)
        cd "\$request_home" || status=1
        if [ "\$status" -eq 0 ]; then
          exec 24<> "\$request_home/state/.test-admission-release-replay" \
            || status=1
        fi
        if [ "\$status" -eq 0 ]; then
          exec 21< <(printf '%s\n' "$nonce")
          python3 "$BROKER" lock-holder --record "$RECORD" --capability-fd 21 \
            <&24 \
            >"\$output.first" 2>&1 &
          first_pid=\$!
          attempts=0
          while [ "\$attempts" -lt 100 ] \
            && ! grep -F 'LOCKED' "\$output.first" >/dev/null 2>&1; do
            if ! kill -0 "\$first_pid" 2>/dev/null; then
              break
            fi
            sleep 0.02
            attempts=\$((attempts + 1))
          done
          if grep -F 'LOCKED' "\$output.first" >/dev/null 2>&1; then
            printf '%s\n' locked > "\$output.locked"
          else
            status=1
          fi
          wait "\$first_pid" || status=1
          python3 "$BROKER" lock-holder --record "$RECORD" --capability-fd 21 \
            < /dev/null >"\$output.second" 2>&1 || second_status=\$?
          printf '%s\n' "\${second_status:-0}" > "\$output.second.status"
          exec 21<&-
          exec 24>&-
        fi
        ;;
      admission-contend)
        cd "\$request_home" || status=1
        if [ "\$status" -eq 0 ]; then
          exec 24<> "\$request_home/state/.test-admission-release-1" \
            || status=1
        fi
        if [ "\$status" -eq 0 ]; then
          exec 21< <(while :; do printf '%s\n' "$nonce"; done)
          python3 "$BROKER" lock-holder --record "$RECORD" --capability-fd 21 \
            <&24 \
            >"\$output.first" 2>&1 &
          first_pid=\$!
          attempts=0
          while [ "\$attempts" -lt 100 ] \
            && ! grep -F 'LOCKED' "\$output.first" >/dev/null 2>&1; do
            if ! kill -0 "\$first_pid" 2>/dev/null; then
              break
            fi
            sleep 0.02
            attempts=\$((attempts + 1))
          done
          if grep -F 'LOCKED' "\$output.first" >/dev/null 2>&1; then
            printf '%s\n' locked > "\$output.locked"
            python3 "$BROKER" lock-holder --record "$RECORD" --capability-fd 21 \
              < /dev/null >"\$output.second" 2>&1 &
            second_pid=\$!
            second_status=0
            wait "\$second_pid" || second_status=\$?
            printf '%s\n' "\$second_status" > "\$output.second.status"
          else
            status=1
          fi
          wait "\$first_pid" || status=1
          exec 21<&-
          exec 24>&-
        fi
        ;;
      rotate)
        cd "\$request_home" || status=1
        if [ "\$status" -eq 0 ] && [ -f "$real_exec" ]; then
          exec 18< <(printf '%s\n' "$rotation_key")
          export FM_SESSION_AUTHORITY_DURABLE_FD=18
          mkdir -p "\$request_home/state/.secondmate-launch-receipts"
          . "\$request_home/bin/fm-session-lock-lib.sh"
          start=\$(fm_session_process_start "\$\$") || status=1
          identity=\$(fm_session_process_identity "\$\$") || status=1
          if [ "\$status" -eq 0 ]; then
            fm_session_launch_receipt_write \\
              "\$request_home/state/.secondmate-launch-receipts/alpha" \\
              alpha "\$request_home" "\$\$" "\$start" "\$identity" \\
              "\$(sed -n '7s/^nonce=//p' "\$request_home/state/.session-authority-enrollment")" \\
              || status=1
          fi
          if [ "\$status" -eq 0 ]; then
            signer_pid=\$(sed -n 's/^signer-pid=//p' \\
              "\$request_home/state/.session-authority-enrollment")
            signer_start=\$(sed -n 's/^signer-start=//p' \\
              "\$request_home/state/.session-authority-enrollment")
            signer_identity=\$(sed -n 's/^signer-identity=//p' \\
              "\$request_home/state/.session-authority-enrollment")
            public_key=\$(sed -n 's/^public-key=//p' \\
              "\$request_home/state/.session-authority-enrollment")
            public_digest=\$(sed -n 's/^public-key-sha256=//p' \\
              "\$request_home/state/.session-authority-enrollment")
            consumer_key=\$(cat "\$request_home/state/.test-consumer-public")
            consumer_digest=\$(cat "\$request_home/state/.test-consumer-digest")
            export ROTATE_OUTPUT="\$output.started" \\
              ROTATE_RELEASE="\$request_home/state/.test-rotation-release"
            export FM_SESSION_ENROLLMENT_SIGNER_PID=\$signer_pid \\
              FM_SESSION_ENROLLMENT_NONCE=\$(sed -n '7s/^nonce=//p' \\
                "\$request_home/state/.session-authority-enrollment") \\
              FM_SESSION_ENROLLMENT_PUBLIC_KEY=\$public_key \\
              FM_SESSION_ENROLLMENT_PUBLIC_SHA256=\$public_digest \\
              FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY=\$consumer_key \\
              FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_SHA256=\$consumer_digest
            cp "$real_exec" "\$request_home/bin/.fm-session-authority-exec.rotate"
            mv "\$request_home/bin/.fm-session-authority-exec.rotate" \\
              "\$request_home/bin/fm-session-authority-exec.sh"
            confirmed=\$(openssl dgst -sha256 \\
              "\$request_home/state/.session-authority-enrollment.accepted" \\
              2>/dev/null | sed 's/^.*= //')
            ticket_data=\$(openssl base64 -A < \\
              "\$request_home/state/.session-authority-enrollment")
            acceptance_data=\$(openssl base64 -A < \\
              "\$request_home/state/.session-authority-enrollment.accepted")
            nonce=\$FM_SESSION_ENROLLMENT_NONCE
            exec "\$request_home/bin/fm-session-authority-exec.sh" \\
              --enrollment-confirmed "\$confirmed" \\
              --enrollment-ticket-data "\$ticket_data" \\
              --enrollment-acceptance-data "\$acceptance_data" \\
              --enrollment-consumer-key "\$consumer_key" \\
              --enrollment-consumer-key-sha256 "\$consumer_digest" \\
              --enrollment-launch "\$nonce" \\
              bash -c 'printf started > "\$ROTATE_OUTPUT"; while [ ! -e "\$ROTATE_RELEASE" ]; do sleep 0.02; done'
          fi
        else
          status=1
        fi
        ;;
      *)
        (
          cd "\$request_home" || exit 1
          case "\$kind" in
            live|durable)
              printf 'fixed-public-test-body' | env \\
                FM_AGENT_ROLE="\$role" FM_AGENT_TASK=alpha \\
                FM_AGENT_OWNER_HOME="\$request_home" \\
                python3 "$BROKER" client --record "$RECORD" --kind "\$kind" >"\$output"
              ;;
            library)
              printf 'library-public-test-body' | env \\
                FM_HOME="\$request_home" FM_ROOT_OVERRIDE="$ROOT" \\
                FM_AGENT_ROLE="\$role" FM_AGENT_TASK=alpha \\
                FM_AGENT_OWNER_HOME="\$request_home" bash -c '
                  . "\$1/bin/fm-session-lock-lib.sh"
                  fm_session_authority_capability_present || exit 1
                  fm_session_authority_hmac
                ' broker-library "$ROOT" >"\$output"
              ;;
            *)
              status=1
              ;;
          esac
        ) || status=1
        ;;
    esac
    printf '%s\n' "\$status" > "\$output.status"
  done
  exec 7<&-
done
SH
  chmod 700 "$launch_script"
  (
    cd "$home" || exit 1
    exec env FM_AGENT_ROLE=secondmate FM_AGENT_TASK=alpha \
      FM_AGENT_OWNER_HOME="$home" FM_SESSION_AUTHORITY_WRAPPER_AUTHORIZED=1 \
      FM_SESSION_ENROLLMENT_NONCE="$nonce" "$launch_script"
  ) > "$home/state/.test-launch.log" 2>&1 &
  LAUNCH_PID=$!
  launch_start=$(test_process_start "$LAUNCH_PID") \
    || fail "authenticated launch fixture did not start"
  launch_identity=$(test_process_identity "$LAUNCH_PID") \
    || fail "authenticated launch fixture has no executable identity"
cat > "$primary_fixture" <<SH
#!/usr/bin/env bash
set -u
while :; do
  exec 7< "$PRIMARY_REQUEST_FIFO"
  IFS='|' read -r kind output ticket task consumer issuer_path endpoint start identity public digest private <&7 || {
    exec 7<&-
    continue
  }
  exec 7<&-
  if [ "\$kind" = root ]; then
    root_status=0
    [ -f "\$consumer/state/.session-primary-root" ] || root_status=1
    printf '%s\\n' "\$root_status" >"\$output.status"
    continue
  fi
  [ "\$kind" = signer ] || continue
  exec 10< "\$private"
  unset FM_TEST_PROCESS FM_TEST_AUTHORITY_BROKER_PID FM_TEST_AUTHORITY_OWNER_PID \
    FM_TEST_AUTHORITY_FD FM_TEST_DURABLE_AUTHORITY_FD FM_TEST_SESSION_LOCK_STABLE_OWNER
  FM_SESSION_AUTHORITY_FD=9 \
  FM_SESSION_AUTHORITY_DURABLE_FD=18 \
  FM_SESSION_AUTHORITY_BROKER_PID=\$(cat "$primary_pid_file") \
  FM_SESSION_AUTHORITY_BROKER_START=\$(sed -n '3s/^start=//p' "$issuer/state/.session-authority") \
  FM_SESSION_AUTHORITY_BROKER_IDENTITY=\$(sed -n '4s/^identity=//p' "$issuer/state/.session-authority") \
  FM_SESSION_AUTHORITY_BROKER_SCRIPT="\$issuer_path/bin/fm-session-authority-exec.sh" \
  FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD=10 \
    FM_SESSION_ENROLLMENT_PUBLIC_KEY="\$public" \
    FM_SESSION_ENROLLMENT_PUBLIC_SHA256="\$digest" \
    export FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD \
    FM_SESSION_AUTHORITY_BROKER_PID \
    FM_SESSION_AUTHORITY_BROKER_START FM_SESSION_AUTHORITY_BROKER_IDENTITY \
    FM_SESSION_AUTHORITY_BROKER_SCRIPT FM_SESSION_ENROLLMENT_PRIVATE_KEY_FD \
    FM_SESSION_ENROLLMENT_PUBLIC_KEY FM_SESSION_ENROLLMENT_PUBLIC_SHA256
  PATH="$random_bin:\$PATH" "\$issuer_path/bin/fm-session-enrollment-signer.sh" "\$ticket" "\$task" "\$consumer" "\$issuer_path" \
    "\$endpoint" "\$start" "\$identity" >"\$output" 2>&1 &
  signer_pid=\$!
  printf '%s\\n' "\$signer_pid" >"\$output.pid"
  wait "\$signer_pid" || true
done
exec 7<&-
SH
  chmod 700 "$primary_fixture"
  PRIMARY_DURABLE_KEY=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
  PRIMARY_LIVE_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  primary_harness_output="$TMP_ROOT/primary-harness-$REQUEST_SEQUENCE.log"
  exec 19< <(while :; do printf '%s\n' "$PRIMARY_LIVE_KEY"; done)
  exec 18< <(while :; do printf '%s\n' "$PRIMARY_DURABLE_KEY"; done)
  (
    cd "$issuer" || exit 1
    exec env FM_TEST_PROCESS=1 FM_TEST_AUTHORITY_FD=19 \
      FM_TEST_DURABLE_AUTHORITY_FD=18 FM_HOME="$issuer" \
      FM_ROOT_OVERRIDE="$issuer" \
      FM_TEST_SESSION_LOCK_STABLE_OWNER=1 \
      FM_TEST_AUTHORITY_HARNESS=1 \
      FM_TEST_AUTHORITY_PROVISION_PRIMARY=1 \
      FM_TEST_AUTHORITY_HARNESS_SCRIPT="$ROOT/tests/fm-test-authority-broker.sh" \
      FM_TEST_AUTHORITY_EXEC_SCRIPT="$issuer/bin/fm-session-authority-exec.sh" \
      FM_TEST_AUTHORITY_BROKER_PID_FILE="$primary_pid_file" \
      "$ROOT/tests/fm-test-authority-broker.sh" \
      --authority-script "$issuer/bin/fm-session-authority-exec.sh" "$primary_fixture"
  ) >"$primary_harness_output" 2>&1 &
  PRIMARY_HARNESS_PID=$!
  attempts=0
  while [ "$attempts" -lt 100 ] && [ ! -s "$primary_pid_file" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -s "$primary_pid_file" ] || fail "trusted primary authority fixture did not publish its broker pid"
  PRIMARY_PID=$(cat "$primary_pid_file")
  [ -n "$(test_process_start "$PRIMARY_PID")" ] \
    || fail "trusted primary authority fixture did not start"
  [ -n "$(test_process_identity "$PRIMARY_PID")" ] \
    || fail "trusted primary authority fixture has no executable identity"
  attempts=0
  while [ "$attempts" -lt 100 ] && [ ! -e "/proc/$PRIMARY_PID/fd/9" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -n "$(readlink "/proc/$PRIMARY_PID/fd/9")" ] \
    || fail "trusted primary authority fixture has no protected descriptor"
  signer_private="$issuer/state/.signer-private"
  signer_public="$issuer/state/.signer-public"
  consumer_key="$issuer/state/.consumer-key"
  consumer_public="$issuer/state/.consumer-public"
  openssl ecparam -name prime256v1 -genkey -noout -out "$signer_private" \
    2>/dev/null || fail "trusted fixture signer key could not be created"
  openssl ec -in "$signer_private" -pubout -outform DER -out "$signer_public" \
    2>/dev/null || fail "trusted fixture signer public key could not be created"
  openssl ecparam -name prime256v1 -genkey -noout -out "$consumer_key" \
    2>/dev/null || fail "trusted fixture consumer key could not be created"
  openssl ec -in "$consumer_key" -pubout -outform DER -out "$consumer_public" \
    2>/dev/null || fail "trusted fixture consumer public key could not be created"
  signer_public_b64=$(openssl base64 -A < "$signer_public")
  signer_digest=$(test_sha256_file "$signer_public")
  consumer_public_b64=$(openssl base64 -A < "$consumer_public")
  consumer_digest=$(test_sha256_file "$consumer_public")
  enrollment="$HOME_DIR/state/.session-authority-enrollment"
  root_output="$TMP_ROOT/root-output-$REQUEST_SEQUENCE"
  printf 'root|%s|||%s|%s||||||\n' "$root_output" "$home" "$issuer" \
    > "$PRIMARY_REQUEST_FIFO"
  attempts=0
  while [ "$attempts" -lt 100 ] && [ ! -f "$root_output.status" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$root_output.status" ] \
    && [ "$(cat "$root_output.status")" = 0 ] \
    && [ -f "$home/state/.session-primary-root" ] \
    || { [ ! -f "$root_output" ] || cat "$root_output" >&2; \
      fail "trusted primary root was not published"; }
  signer_output="$TMP_ROOT/signer-output-$REQUEST_SEQUENCE"
  printf 'signer|%s|%s|alpha|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$signer_output" "$enrollment" "$home" "$issuer" "$LAUNCH_PID" "$launch_start" \
    "$launch_identity" "$signer_public_b64" "$signer_digest" "$signer_private" \
    > "$PRIMARY_REQUEST_FIFO"
  while [ "$attempts" -lt 100 ] && [ ! -f "$enrollment.ready" ]; do
    [ -f "$signer_output.pid" ] && SIGNER_PID=$(cat "$signer_output.pid")
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$enrollment" ] && [ -f "$enrollment.ready" ] \
    || { [ ! -f "$signer_output" ] || cat "$signer_output" >&2; \
      fail "trusted primary signer did not publish an enrollment ticket"; }
  [ -f "$signer_output.pid" ] && SIGNER_PID=$(cat "$signer_output.pid") \
    || fail "trusted primary signer did not publish its process identity"
  nonce=$(sed -n '7s/^nonce=//p' "$enrollment")
  accepted_body=$(mktemp "$TMP_ROOT/accepted.XXXXXX")
  accepted_signature=$(mktemp "$TMP_ROOT/accepted-signature.XXXXXX")
  printf 'version=2\nsigner-pid=%s\nnonce=%s\nconsumer-pid=%s\nconsumer-start=%s\nconsumer-public-key-sha256=%s\n' \
    "$SIGNER_PID" "$nonce" "$LAUNCH_PID" "$launch_start" \
    "$consumer_digest" > "$accepted_body"
  openssl dgst -sha256 -sign "$signer_private" -out "$accepted_signature" \
    "$accepted_body" 2>/dev/null || fail "trusted fixture acceptance could not be signed"
  printf '%s\nsignature=%s\n' "$(cat "$accepted_body")" \
    "$(openssl base64 -A < "$accepted_signature")" \
    > "$enrollment.accepted"
  accepted_digest=$(test_sha256_file "$enrollment.accepted")
  final_body=$(mktemp "$TMP_ROOT/final.XXXXXX")
  final_signature=$(mktemp "$TMP_ROOT/final-signature.XXXXXX")
  printf 'version=2\nstage=final\nsigner-pid=%s\nnonce=%s\nconsumer-pid=%s\nconsumer-start=%s\nacceptance-sha256=%s\nconsumer-public-key-sha256=%s\n' \
    "$SIGNER_PID" "$nonce" "$LAUNCH_PID" "$launch_start" \
    "$accepted_digest" "$consumer_digest" > "$final_body"
  openssl dgst -sha256 -sign "$consumer_key" -out "$final_signature" \
    "$final_body" 2>/dev/null || fail "trusted fixture final receipt could not be signed"
  printf '%s\nsignature=%s\n' "$(cat "$final_body")" \
    "$(openssl base64 -A < "$final_signature")" \
    > "$enrollment.accepted.final"
  TRUSTED_TICKET_B64=$(openssl base64 -A < "$enrollment")
  TRUSTED_ACCEPTANCE_B64=$(openssl base64 -A < "$enrollment.accepted")
  TRUSTED_FINAL_B64=$(openssl base64 -A < "$enrollment.accepted.final")
  TRUSTED_CONSUMER_KEY_B64=$consumer_public_b64
  printf '%s\n' "$TRUSTED_CONSUMER_KEY_B64" > "$home/state/.test-consumer-public"
  printf '%s\n' "$consumer_digest" > "$home/state/.test-consumer-digest"
  receipt_body=$(printf 'version=1\ntask=alpha\nhome=%s\npid=%s\nstart=%s\nidentity=%s\nnonce=%s' \
    "$home" "$LAUNCH_PID" "$launch_start" "$launch_identity" "$nonce")
  receipt_body="${receipt_body}"$'\n'
  receipt_hmac=$(BROKER_KEY="$BROKER_KEY" RECEIPT_BODY="$receipt_body" \
    python3 -c 'import hashlib, hmac, os; print(hmac.new(bytes.fromhex(os.environ["BROKER_KEY"]), os.environ["RECEIPT_BODY"].encode(), hashlib.sha256).hexdigest())')
  printf '%sauthority-hmac=%s\n' "$receipt_body" "$receipt_hmac" \
    > "$home/state/.session-authority-launch"
  LAUNCH_SCRIPT="$launch_script"
}

start_broker() {
  local evidence_fd receipt_b64 attempts=0 broker_output
  receipt_b64=$(openssl base64 -A < "$HOME_DIR/state/.session-authority-launch") \
    || fail "could not encode authenticated launch evidence"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$BROKER_KEY" "$receipt_b64" "$TRUSTED_TICKET_B64" \
    "$TRUSTED_ACCEPTANCE_B64" "$TRUSTED_FINAL_B64" \
    "$TRUSTED_CONSUMER_KEY_B64" > "$HOME_DIR/state/.test-launch-evidence"
  broker_output="$TMP_ROOT/broker-pid-$REQUEST_SEQUENCE"
  REQUEST_SEQUENCE=$((REQUEST_SEQUENCE + 1))
  printf 'broker|secondmate|%s|%s\n' "$HOME_DIR" "$broker_output" > "$REQUEST_FIFO"
  while [ "$attempts" -lt 100 ] && [ ! -f "$RECORD" ]; do
    if [ -f "$broker_output" ] && [ -z "$BROKER_PID" ]; then
      BROKER_PID=$(cat "$broker_output")
    fi
    if [ -n "$BROKER_PID" ]; then
      kill -0 "$BROKER_PID" 2>/dev/null \
        || fail "authority broker exited before publishing its record"
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] \
    || fail "authority broker did not publish a private regular record"
}

test_same_home_secondmate_admission_allows_hmac_before_release() {
  local output attempts=0
  output="$TMP_ROOT/admission-output-$REQUEST_SEQUENCE"
  REQUEST_SEQUENCE=$((REQUEST_SEQUENCE + 1))
  rm -f "$output" "$output.status" "$output.probe" "$output.probe.status"
  printf 'admission|secondmate|%s|%s\n' "$HOME_DIR" "$output" > "$REQUEST_FIFO"
  while [ "$attempts" -lt 150 ] && [ ! -f "$output.probe.status" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$output.probe.status" ] \
    && [ "$(cat "$output.probe.status")" = 0 ] \
    || fail "same-home admission blocked broker HMAC requests"
  printf 'RELEASE\n' > "$HOME_DIR/state/.test-admission-release"
  attempts=0
  while [ "$attempts" -lt 150 ] && [ ! -f "$output.status" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$output.status" ] && [ "$(cat "$output.status")" = 0 ] \
    || fail "same-home admission did not release cleanly"
  pass "same-home admission serves HMAC requests before release"
}

test_same_home_secondmate_admission_serializes_independent_holders() {
  local output attempts=0 second_status
  output="$TMP_ROOT/admission-contend-output-$REQUEST_SEQUENCE"
  REQUEST_SEQUENCE=$((REQUEST_SEQUENCE + 1))
  rm -f "$output" "$output.status" "$output.locked" \
    "$output.second.status"
  printf 'admission-contend|secondmate|%s|%s\n' "$HOME_DIR" "$output" \
    > "$REQUEST_FIFO"
  while [ "$attempts" -lt 150 ] && [ ! -f "$output.second.status" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$output.locked" ] || fail "same-home admission did not hold first lease"
  [ -f "$output.second.status" ] || \
    fail "same-home admission did not reject the competing holder"
  second_status=$(cat "$output.second.status")
  [ "$second_status" -ne 0 ] || \
    fail "same-home admission allowed competing holders"
  printf 'RELEASE\n' > "$HOME_DIR/state/.test-admission-release-1"
  attempts=0
  while [ "$attempts" -lt 150 ] && [ ! -f "$output.status" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$output.status" ] && [ "$(cat "$output.status")" = 0 ] \
    || fail "same-home admission did not release its first holder"
  pass "same-home admission serializes independent holders"
}

test_same_home_secondmate_admission_rejects_replay() {
  local output attempts=0 second_status
  output="$TMP_ROOT/admission-replay-output-$REQUEST_SEQUENCE"
  REQUEST_SEQUENCE=$((REQUEST_SEQUENCE + 1))
  rm -f "$output" "$output.status" "$output.locked" \
    "$output.first" "$output.second" "$output.second.status"
  printf 'admission-replay|secondmate|%s|%s\n' "$HOME_DIR" "$output" \
    > "$REQUEST_FIFO"
  while [ "$attempts" -lt 150 ] && [ ! -f "$output.locked" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$output.locked" ] || fail "real admission replay fixture did not acquire"
  printf 'RELEASE\n' > "$HOME_DIR/state/.test-admission-release-replay"
  attempts=0
  while [ "$attempts" -lt 150 ] && [ ! -f "$output.second.status" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$output.second.status" ] || \
    fail "real admission replay fixture did not test the consumed capability"
  second_status=$(cat "$output.second.status")
  [ "$second_status" -ne 0 ] || \
    fail "real admission capability was replayed after release"
  attempts=0
  while [ "$attempts" -lt 150 ] && [ ! -f "$output.status" ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$output.status" ] && [ "$(cat "$output.status")" = 0 ] \
    || fail "real admission replay fixture did not finish cleanly"
  pass "real admission capabilities reject one-shot replay"
}

test_rebound_broker_name_rejects_peer_mismatch() {
  if ! python3 - "$BROKER" "$RECORD" "$HOME_DIR" <<'PY'
import os
import socket
import subprocess
import sys
from pathlib import Path

broker, record_name, home = map(Path, sys.argv[1:])
original = Path(record_name).read_text(encoding="utf-8")
rebound = f"fm-test-rebound-{os.getpid()}"
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind("\0" + rebound)
server.listen(1)
try:
    Path(record_name).write_text(
        original.replace(
            next(line for line in original.splitlines() if line.startswith("socket=")),
            f"socket=abstract:{rebound}",
        )
        + ("" if original.endswith("\n") else "\n"),
        encoding="utf-8",
    )
    result = subprocess.run(
        [str(broker), "client", "--record", str(record_name), "--kind", "live"],
        cwd=str(home),
        env={
            **os.environ,
            "FM_AGENT_ROLE": "secondmate",
            "FM_AGENT_TASK": "alpha",
            "FM_AGENT_OWNER_HOME": str(home),
        },
        input=b"rebound-test",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=2,
    )
    if result.returncode == 0:
        raise SystemExit("a rebound abstract endpoint passed peer authentication")
    server.settimeout(1)
    try:
        connection, _ = server.accept()
    except socket.timeout:
        pass
    else:
        connection.close()
finally:
    Path(record_name).write_text(original, encoding="utf-8")
    server.close()
PY
  then
    fail "rebound broker endpoint was accepted"
  fi
  pass "rebound broker names cannot replace the authenticated endpoint"
}

test_stale_recovery_requires_inherited_capability() {
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_recovery_capability", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    home = Path(temporary)
    state = home / "state"
    state.mkdir()
    record = state / ".session-authority-broker"
    record.write_text("record\n", encoding="utf-8")
    launch_script = home / "bin" / "fm-session-authority-exec.sh"
    metadata = {
        "version": "1",
        "pid": "999999",
        "start": "proc:broker",
        "identity": "exe:broker",
        "socket": "abstract:broker",
        "home": str(home),
        "checkout": str(broker_path.parent.parent),
        "task": "task",
        "script": str(broker_path),
        "launch-pid": "999998",
        "launch-start": "proc:dead",
        "launch-identity": "exe:dead",
        "launch-script": str(launch_script),
        "uid": str(os.geteuid()),
        "gid": str(os.getegid()),
    }
    args = SimpleNamespace(
        record=str(record),
        state=str(state),
        home=str(home),
        checkout=str(broker_path.parent.parent),
        task="task",
        launch_script=str(launch_script),
        record_lock_fd=-1,
    )
    broker.read_record_shape = lambda _path: metadata
    broker.process_generation_for_recovery = lambda _pid: None
    deleted = []
    broker.unlink_owned_record = lambda *_args, **_kwargs: deleted.append(True) or True
    evidence = (b"authenticated-root", os.getppid(), "proc:launch", "exe:launch")
    if broker.recover_stale_locked(args, launch_evidence=evidence) == 0:
        raise SystemExit("stale recovery used a path-only fallback")
    if deleted:
        raise SystemExit("unauthenticated stale recovery reached record deletion")

    read_fd, write_fd = os.pipe()
    os.write(write_fd, b"a" * 96 + b"\n")
    os.close(write_fd)
    saved = None
    try:
        try:
            saved = os.dup(broker.AUTHORITY_SERIALIZATION_FD)
        except OSError:
            pass
        if read_fd != broker.AUTHORITY_SERIALIZATION_FD:
            os.dup2(read_fd, broker.AUTHORITY_SERIALIZATION_FD)
            os.close(read_fd)
        args.record_lock_fd = broker.AUTHORITY_SERIALIZATION_FD
        if broker.recover_stale_locked(args, launch_evidence=evidence) != 0:
            raise SystemExit("authenticated stale recovery did not use the inherited capability")
        if not deleted:
            raise SystemExit("authenticated stale recovery did not reach deletion")
    finally:
        try:
            os.close(broker.AUTHORITY_SERIALIZATION_FD)
        except OSError:
            pass
        if saved is not None:
            os.dup2(saved, broker.AUTHORITY_SERIALIZATION_FD)
            os.close(saved)
PY
  then
    fail "stale recovery capability authentication regressed"
  fi
  pass "stale recovery requires an inherited authenticated capability"
}

if [ "${FM_SESSION_AUTHORITY_BROKER_FOCUS:-}" = review-fixes-integration ]; then
  test_concurrent_broker_start_has_one_publisher
  mkdir -p "$STATE" "$FOREIGN_HOME"
  prepare_launch "$HOME_DIR"
  start_broker
  test_stale_recovery_requires_inherited_capability
  test_same_home_secondmate_admission_allows_hmac_before_release
  test_same_home_secondmate_admission_rejects_replay
  test_rebound_broker_name_rejects_peer_mismatch
  test_same_home_secondmate_admission_serializes_independent_holders
  exit 0
fi

prepare_rotation_launch() {
  local home=$1 primary="$TMP_ROOT/rotation-primary"
  local state="$home/state" primary_state="$primary/state"
  local launch_script="$home/bin/fm-session-authority-exec.sh"
  local real_exec="$home/bin/.fm-real-session-authority-exec.sh"
  local provisioner="$primary/bin/fm-rotation-primary-provision.sh"
  local request="$home/state/.test-rotation-request"
  local root_ready="$home/state/.test-rotation-root-ready"
  local ticket_ready="$home/state/.test-rotation-ticket-ready"
  local launch_ready="$home/.test-rotation-launch"
  local enrollment="$state/.session-authority-enrollment"
  local random_bin="$home/test-bin" old_pid old_start old_owner
  local quoted_home quoted_primary quoted_root_ready
  local signer_pid signer_public signer_digest nonce consumer_private
  local consumer_public consumer_digest accepted_digest tmp external_custodian
  sleep 2
  mkdir -p "$home/bin" "$state" "$primary/bin" "$primary_state" "$random_bin"
  fm_git_init_commit "$home"
  fm_git_init_commit "$primary"
  git -C "$home" branch -M main
  git -C "$primary" branch -M main
  cat > "$random_bin/od" <<'SH'
#!/usr/bin/env bash
case "${3:-}" in
  48) printf '%096d\n' 0 | tr 0 a ;;
  32) printf '%064d\n' 0 | tr 0 a ;;
  *) exec /usr/bin/od "$@" ;;
esac
SH
  chmod 700 "$random_bin/od"
  cp "$ROOT"/bin/*.sh "$home/bin/"
  cp "$ROOT/bin/fm-session-authority-broker.py" "$home/bin/"
  cp "$ROOT"/bin/*.sh "$primary/bin/"
  cp "$ROOT/bin/fm-session-authority-broker.py" "$primary/bin/"
  chmod 700 "$home/bin"/*.sh "$home/bin/fm-session-authority-broker.py" \
    "$primary/bin"/*.sh "$primary/bin/fm-session-authority-broker.py"
  cp "$launch_script" "$real_exec"
  printf -v quoted_home '%q' "$home"
  printf -v quoted_primary '%q' "$primary"
  printf -v quoted_root_ready '%q' "$root_ready"
  awk -v home="$quoted_home" -v primary="$quoted_primary" \
    -v root_ready="$quoted_root_ready" '
    /^fm_session_authority_admission_release \|\| \{/ {
      print "fm_session_primary_root_write alpha " home " " primary " " primary " bootstrap || exit 1"
      print "printf root-ready > " root_ready
    }
    { print }
  ' "$primary/bin/fm-session-authority-exec.sh" \
    > "$primary/bin/.fm-session-authority-exec.sh.tmp"
  chmod 700 "$primary/bin/.fm-session-authority-exec.sh.tmp"
  mv "$primary/bin/.fm-session-authority-exec.sh.tmp" \
    "$primary/bin/fm-session-authority-exec.sh"
  (
    cd "$home" || exit 1
    exec 9<&- 18<&- 2>/dev/null || true
    exec env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      -u FM_SESSION_AUTHORITY_FD -u FM_SESSION_AUTHORITY_DURABLE_FD \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
      PATH="$random_bin:$PATH" bash "$launch_script" \
      bash -c 'while :; do sleep 60; done'
  ) > "$state/.test-old-primary.log" 2>&1 &
  old_pid=$!
  ROTATION_CUSTODIAN_PID=
  for _ in $(seq 1 1000); do
    [ -f "$state/.session-durable-authority" ] && break
    sleep 0.02
  done
  [ -f "$state/.session-authority" ] \
    && [ -f "$state/.session-authority-live" ] \
    && [ -f "$state/.session-durable-authority" ] \
    || { cat "$state/.test-old-primary.log" >&2; \
      fail "old primary did not publish rotation authority"; }
  printf '%s\n' alpha > "$home/.fm-secondmate-home"
  ROTATION_CUSTODIAN_PID=$(sed -n '2s/^pid=//p' \
    "$state/.session-durable-authority")
  old_owner=$(sed -n '2s/^pid=//p' "$state/.session-authority")
  kill "$old_pid" 2>/dev/null || true
  wait "$old_pid" 2>/dev/null || true
  kill -0 "$old_owner" 2>/dev/null \
    && fail "old rotation authority remained live"
  consumer_private=$(openssl ecparam -name prime256v1 -genkey -noout)
  consumer_public=$(printf '%s\n' "$consumer_private" \
    | openssl ec -pubout 2>/dev/null | openssl base64 -A)
  consumer_digest=$(printf '%s' "$consumer_public" | openssl base64 -d -A \
    | openssl dgst -sha256 | sed 's/^.*= //')
  printf '%s\n' "$consumer_private" > "$state/.test-rotation-consumer-private"
  printf '%s\n' "$consumer_public" > "$state/.test-rotation-consumer-public"
  printf '%s\n' "$consumer_digest" > "$state/.test-rotation-consumer-digest"
  chmod 600 "$state/.test-rotation-consumer-private"
  mkfifo "$request"
  cat > "$launch_script" <<SH
#!/usr/bin/env bash
set -eu
main() {
while [ ! -f "$launch_ready" ]; do sleep 0.02; done
exec 18< <(while :; do printf '%s\\n' "$(printf '%096d' 0 | tr 0 a)"; done)
export FM_SESSION_AUTHORITY_DURABLE_FD=18
export FM_SESSION_ENROLLMENT_SIGNER_PID=\$(cat "$state/.test-rotation-signer-pid")
export FM_SESSION_ENROLLMENT_NONCE=\$(sed -n '7s/^nonce=//p' "$enrollment")
export FM_SESSION_ENROLLMENT_PUBLIC_KEY=\$(sed -n '17s/^public-key=//p' "$enrollment")
export FM_SESSION_ENROLLMENT_PUBLIC_SHA256=\$(sed -n '18s/^public-key-sha256=//p' "$enrollment")
export FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY=\$(cat "$state/.test-rotation-consumer-public")
export FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_SHA256=\$(cat "$state/.test-rotation-consumer-digest")
export FM_SESSION_ENROLLMENT_CONSUMER_PRIVATE_KEY=\$(cat "$state/.test-rotation-consumer-private")
. "$home/bin/fm-session-lock-lib.sh"
mkdir -p "$state/.secondmate-launch-receipts"
start=\$(fm_session_process_start "\$\$")
identity=\$(fm_session_process_identity "\$\$")
fm_session_launch_receipt_write \\
  "$state/.secondmate-launch-receipts/alpha" alpha "$home" "\$\$" \\
  "\$start" "\$identity" "\$FM_SESSION_ENROLLMENT_NONCE"
export ROTATE_OUTPUT="$state/.test-rotation.started" \\
  ROTATE_RELEASE="$state/.test-rotation-release"
exec "$launch_script" \\
  --enrollment-launch "\$FM_SESSION_ENROLLMENT_NONCE" \\
  --enrollment-consumer-key "\$FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_KEY" \\
  --enrollment-consumer-key-sha256 "\$FM_SESSION_ENROLLMENT_CONSUMER_PUBLIC_SHA256" \\
  bash -c 'printf started > "\$ROTATE_OUTPUT"; while [ ! -e "\$ROTATE_RELEASE" ]; do sleep 0.02; done'
}
main "\$@"
SH
  chmod 700 "$launch_script"
  cat > "$provisioner" <<SH
#!/usr/bin/env bash
set -eu
. "$primary/bin/fm-session-lock-lib.sh"
while [ ! -f "$root_ready" ]; do sleep 0.02; done
IFS='|' read -r endpoint endpoint_start endpoint_identity < "$request"
fm_session_enrollment_signer_prepare
export FM_SESSION_AUTHORITY_BROKER_SCRIPT="$primary/bin/fm-session-authority-exec.sh"
"$primary/bin/fm-session-enrollment-signer.sh" \\
  --public-sha256 "\$FM_SESSION_ENROLLMENT_PUBLIC_SHA256" \\
  "$enrollment" alpha "$home" "$primary" "\$endpoint" \\
  "\$endpoint_start" "\$endpoint_identity" > "$state/.test-rotation-signer.log" 2>&1 &
signer=\$!
printf '%s\n' "\$signer" > "$state/.test-rotation-signer-pid"
touch "$ticket_ready"
wait "\$signer"
SH
  chmod 700 "$provisioner"
  (
    cd "$home" || exit 1
    exec env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
      FM_AGENT_ROLE=secondmate FM_AGENT_TASK=alpha \
      FM_AGENT_OWNER_HOME="$home" "$launch_script"
  ) > "$state/.test-rotation-launch.log" 2>&1 &
  LAUNCH_PID=$!
  launch_start=$(test_process_start "$LAUNCH_PID") || return 1
  launch_identity=$(test_process_identity "$LAUNCH_PID") || return 1
  (
    cd "$primary" || exit 1
    exec 9<&- 18<&- 2>/dev/null || true
    exec env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      -u FM_SESSION_AUTHORITY_FD -u FM_SESSION_AUTHORITY_DURABLE_FD \
      FM_HOME="$primary" FM_ROOT_OVERRIDE="$primary" \
      PATH="$primary/test-bin:$PATH" "$primary/bin/fm-session-authority-exec.sh" \
      "$provisioner"
  ) > "$primary_state/.test-rotation-primary.log" 2>&1 &
  ROTATION_PRIMARY_SETUP_PID=$!
  for _ in $(seq 1 1000); do
    [ -f "$root_ready" ] && break
    sleep 0.02
  done
  [ -f "$root_ready" ] || {
    cat "$primary_state/.test-rotation-primary.log" >&2
    fail "production primary did not publish the secondary root"
  }
  printf '%s|%s|%s\n' "$LAUNCH_PID" "$launch_start" "$launch_identity" > "$request"
  for _ in $(seq 1 1000); do
    [ -f "$ticket_ready" ] && [ -f "$enrollment.ready" ] && break
    sleep 0.02
  done
  [ -f "$enrollment" ] && [ -f "$enrollment.ready" ] \
    || {
      cat "$state/.test-rotation-signer.log" >&2 2>/dev/null || true
      fail "production signer did not publish the enrollment ticket"
    }
  cp "$real_exec" "$launch_script"
  touch "$launch_ready"
  for _ in $(seq 1 1000); do
    [ -f "$enrollment.accepted" ] && break
    sleep 0.02
  done
  [ -f "$enrollment.accepted" ] || {
    cat "$state/.test-rotation-signer.log" >&2 2>/dev/null || true
    fail "production signer did not publish acceptance"
  }
  external_custodian=$(sed -n '2s/^pid=//p' \
    "$primary_state/.session-durable-authority" 2>/dev/null || true)
  [ -z "$external_custodian" ] || kill "$external_custodian" 2>/dev/null || true
}

test_same_home_secondmate_rotation_uses_admission_capability() {
  local rotation_home="$TMP_ROOT/rotation-home" output attempts=0
  local live_pid live_start live_identity live_descriptor
  rm -f "$rotation_home/state/.test-rotation-release" \
    "$rotation_home/state/.test-rotation.started"
  prepare_rotation_launch "$rotation_home"
  output="$TMP_ROOT/rotation-output"
  while [ "$attempts" -lt 1000 ] \
    && { [ ! -f "$rotation_home/state/.test-rotation.started" ] \
      || [ ! -f "$rotation_home/state/.session-authority-live" ] \
      || [ "$(sed -n '2s/^pid=//p' \
        "$rotation_home/state/.session-authority-live" 2>/dev/null)" \
        != "$LAUNCH_PID" ]; }; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$rotation_home/state/.test-rotation.started" ] \
    || { [ ! -f "$rotation_home/state/.test-launch.log" ] \
      || cat "$rotation_home/state/.test-launch.log" >&2; \
      fail "real secondmate wrapper did not start its child"; }
  live_pid=$(sed -n '2s/^pid=//p' "$rotation_home/state/.session-authority-live")
  live_start=$(sed -n '3s/^start=//p' "$rotation_home/state/.session-authority-live")
  live_identity=$(sed -n '4s/^identity=//p' \
    "$rotation_home/state/.session-authority-live")
  live_descriptor=$(sed -n '6s/^descriptor=//p' \
    "$rotation_home/state/.session-authority-live")
  [ "$live_pid" = "$LAUNCH_PID" ] \
    && [ "$live_start" = "$(test_process_start "$LAUNCH_PID")" ] \
    && [ "$live_identity" = "$(test_process_identity "$LAUNCH_PID")" ] \
    && [ "$live_descriptor" = "$(readlink "/proc/$LAUNCH_PID/fd/9")" ] \
    || fail "real secondmate rotation did not publish its live binding"
  : > "$rotation_home/state/.test-rotation-release"
  attempts=0
  while [ "$attempts" -lt 250 ] && kill -0 "$LAUNCH_PID" 2>/dev/null; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  kill -0 "$LAUNCH_PID" 2>/dev/null \
    && fail "real secondmate wrapper did not release its child"
  pass "same-home secondmate rotation publishes an authenticated live binding"
}

broker_hmac() {
  local home=$1 role=$2 kind=$3 output status attempts=0
  output="$TMP_ROOT/request-${BASHPID:-$$}-$REQUEST_SEQUENCE"
  REQUEST_SEQUENCE=$((REQUEST_SEQUENCE + 1))
  printf '%s|%s|%s|%s\n' "$kind" "$role" "$home" "$output" > "$REQUEST_FIFO"
  while [ "$attempts" -lt 100 ]; do
    if [ -f "$output.status" ]; then
      status=$(cat "$output.status")
      [ "$status" = 0 ] || return 1
      cat "$output"
      return 0
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  return 1
}

broker_direct_hmac() {
  local home=$1 role=$2 kind=$3
  (cd "$home" && printf 'fixed-public-test-body' | env \
    FM_AGENT_ROLE="$role" FM_AGENT_TASK=alpha FM_AGENT_OWNER_HOME="$home" \
    python3 "$BROKER" client --record "$RECORD" --kind "$kind")
}

broker_library_hmac() {
  broker_hmac "$HOME_DIR" secondmate library
}

if [ "${FM_SESSION_AUTHORITY_BROKER_FOCUS:-}" = rotation ]; then
  test_same_home_secondmate_rotation_uses_admission_capability
  exit 0
fi

test_inherited_capability_requires_anonymous_pipe
mkdir -p "$STATE" "$FOREIGN_HOME"
prepare_launch "$HOME_DIR"
start_broker
[ "$(stat -c '%a' "$RECORD")" = 600 ] \
  || fail "authority broker record was not private"
test_same_home_secondmate_admission_allows_hmac_before_release
test_same_home_secondmate_admission_rejects_replay
test_same_home_secondmate_admission_serializes_independent_holders
test_rebound_broker_name_rejects_peer_mismatch

live=$(broker_hmac "$HOME_DIR" secondmate live) \
  || fail "same-home secondmate could not use live broker authority"
durable_one=$(broker_hmac "$HOME_DIR" secondmate durable) \
  || fail "same-home secondmate could not use durable broker authority"
durable_two=$(broker_hmac "$HOME_DIR" secondmate durable) \
  || fail "same-home durable authority was not reusable"
case "$live:$durable_one" in
  *[!0-9a-f:]*|:*|*::*|*:) fail "authority broker returned a malformed digest" ;;
esac
[ "${#live}" -eq 64 ] && [ "${#durable_one}" -eq 64 ] \
  && [ "$live" != "$durable_one" ] && [ "$durable_one" = "$durable_two" ] \
  || fail "broker did not retain separate live and durable in-memory authority"
pass "peer-credential broker retains separate live and durable authority"

if broker_direct_hmac "$HOME_DIR" secondmate live >/dev/null 2>&1; then
  fail "a same-home caller without authenticated launch ancestry used broker authority"
fi
pass "peer-credential broker rejects forgeable same-home client metadata"

if broker_hmac "$FOREIGN_HOME" secondmate live >/dev/null 2>&1; then
  fail "cross-home secondmate used another home's authority broker"
fi
pass "peer-credential broker rejects a cross-home secondmate"

if broker_hmac "$HOME_DIR" crewmate live >/dev/null 2>&1; then
  fail "declared crewmate used secondmate authority"
fi
if (cd "$HOME_DIR" && FM_AGENT_ROLE=crewmate FM_AGENT_TASK=nested \
    FM_AGENT_OWNER_HOME="$HOME_DIR" bash -c '
      printf fixed-public-test-body | env FM_AGENT_ROLE=secondmate \
        FM_AGENT_TASK=alpha FM_AGENT_OWNER_HOME="$1" \
        python3 "$2" client --record "$3" --kind live
    ' broker-test "$HOME_DIR" "$BROKER" "$RECORD") >/dev/null 2>&1; then
  fail "crewmate ancestor forged a secondmate broker request"
fi
pass "peer-credential broker rejects crewmate callers and forged descendants"

if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

home = "/test/home"
script = str(broker_path)

def canonical(value):
    return script if value == script else home

broker.canonical = canonical
broker.os.readlink = lambda path: home if path.endswith("/cwd") else "/usr/bin/python3"
broker.process_command = lambda pid: ["python3", script, "client"]
broker.process_start = lambda pid: "proc:x"
broker.process_identity = lambda pid: "exe:x"
broker.process_environment = lambda pid: {
    "FM_AGENT_ROLE": "secondmate",
    "FM_AGENT_TASK": "alpha",
    "FM_AGENT_OWNER_HOME": home,
}
broker.parent_pid = lambda pid: pid + 1

if broker.peer_is_authorized(
    42, uid=1000, gid=1000, home=home, task="alpha", script=script,
    launch_pid=999, launch_start="proc:x", launch_identity="exe:x",
    broker_uid=1000, broker_gid=1000
):
    raise SystemExit("bounded ancestry walk authorized without reaching the launch process")
PY
then
  fail "the broker authorized a bounded ancestry walk that never reached the launch process"
fi
pass "peer-credential broker fails closed when ancestry depth is exhausted"

if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import socket
import sys
import time
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

left, right = socket.socketpair()
try:
    started = time.monotonic()
    try:
        broker.recv_exact(left, 1, started + 0.05)
    except TimeoutError:
        pass
    else:
        raise SystemExit("a partial broker request was not deadline bounded")
    if time.monotonic() - started > 1:
        raise SystemExit("broker request deadline was not hard bounded")
    start, identity = broker.process_generation(os.getpid())
    metadata = {
        "pid": str(os.getpid()),
        "uid": str(os.geteuid()),
        "gid": str(os.getegid()),
        "start": start,
        "identity": identity,
    }
    if not broker.connected_peer_matches_record(left, metadata):
        raise SystemExit("the connected peer generation did not match its record")
    metadata["start"] = "proc:stale"
    if broker.connected_peer_matches_record(left, metadata):
        raise SystemExit("a stale connected peer generation was accepted")
finally:
    left.close()
    right.close()
PY
then
  fail "the broker did not bound partial reads or authenticate the connected peer"
fi
pass "peer-credential broker bounds partial reads and revalidates connected generation"

if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

home = "/test/home"
script = str(broker_path)
broker.canonical = lambda value: value
broker.os.readlink = lambda path: home if path.endswith("/cwd") else "/usr/bin/python3"
broker.process_command = lambda pid: ["python3", script, "client"]
broker.process_generation = lambda pid: ("proc:x", "exe:x")
broker.process_environment = lambda pid: {
    42: {
        "FM_AGENT_ROLE": "secondmate",
        "FM_AGENT_TASK": "alpha",
        "FM_AGENT_OWNER_HOME": home,
    },
    43: {
        "FM_AGENT_ROLE": "secondmate",
        "FM_AGENT_TASK": "foreign",
        "FM_AGENT_OWNER_HOME": home,
    },
    44: {},
}[pid]
broker.parent_pid = lambda pid: {42: 43, 43: 44}[pid]

if broker.peer_is_authorized(
    42, uid=1000, gid=1000, home=home, task="alpha", script=script,
    launch_pid=44, launch_start="proc:x", launch_identity="exe:x",
    broker_uid=1000, broker_gid=1000
):
    raise SystemExit("a mismatched secondmate ancestor was accepted")
PY
then
  fail "the broker did not validate every secondmate ancestor scope"
fi
pass "peer-credential broker rejects mismatched secondmate ancestors"

if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

home = "/test/home"
script = str(broker_path)
for role in ("", "primary", "unknown"):
    broker.canonical = lambda value: value
    broker.os.readlink = lambda path: home if path.endswith("/cwd") else "/usr/bin/python3"
    broker.process_command = lambda pid: ["python3", script, "client"]
    broker.process_generation = lambda pid: ("proc:x", "exe:x")
    broker.process_environment = lambda pid, role=role: {
        42: {
            "FM_AGENT_ROLE": "secondmate",
            "FM_AGENT_TASK": "alpha",
            "FM_AGENT_OWNER_HOME": home,
        },
        43: {"FM_AGENT_ROLE": role},
        44: {
            "FM_AGENT_ROLE": "secondmate",
            "FM_AGENT_TASK": "alpha",
            "FM_AGENT_OWNER_HOME": home,
        },
    }[pid]
    broker.parent_pid = lambda pid: {42: 43, 43: 44}[pid]
    if broker.peer_is_authorized(
        42, uid=1000, gid=1000, home=home, task="alpha", script=script,
        launch_pid=44, launch_start="proc:x", launch_identity="exe:x",
        broker_uid=1000, broker_gid=1000
    ):
        raise SystemExit(f"an undeclared {role or 'empty'} ancestor was accepted")
PY
then
  fail "the broker accepted an undeclared ancestry gap"
fi
pass "peer-credential broker rejects empty, primary, and unknown ancestors"

if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

home = "/test/home"
script = str(broker_path)

def canonical(value):
    return script if value == script else home

broker.canonical = canonical
broker.os.readlink = lambda path: home if path.endswith("/cwd") else "/usr/bin/python3"
broker.process_command = lambda pid: ["python3", script, "client"]
broker.process_start = lambda pid: "proc:x"
broker.process_identity = lambda pid: "exe:x"
broker.parent_pid = lambda pid: pid

def authorized(owner_home):
    broker.process_environment = lambda pid: {
        "FM_AGENT_ROLE": "secondmate",
        "FM_AGENT_TASK": "alpha",
        **({} if owner_home is None else {"FM_AGENT_OWNER_HOME": owner_home}),
    }
    return broker.peer_is_authorized(
        42, uid=1000, gid=1000, home=home, task="alpha", script=script,
        launch_pid=42, launch_start="proc:x", launch_identity="exe:x",
        broker_uid=1000, broker_gid=1000
    )

if not authorized(home):
    raise SystemExit("explicit absolute owner home was rejected")
if authorized(None):
    raise SystemExit("missing owner home was accepted")
if authorized("relative/home"):
    raise SystemExit("relative owner home was accepted")
PY
then
  fail "the broker did not enforce an explicit absolute owner home"
fi
pass "peer-credential broker rejects missing and relative owner homes"

if ! python3 - "$BROKER" "$BROKER_KEY" <<'PY'
import hashlib
import hmac
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

root_key = bytes.fromhex(sys.argv[2])
body = b"durable-capability-boundary"
root_digest = hmac.new(root_key, body, hashlib.sha256).hexdigest()
scoped_key = broker.derive_broker_durable_key(
    root_key, task="alpha", home="/test/home", launch_pid=42,
    launch_start="proc:x", launch_identity="exe:x",
    launch_script="/test/home/bin/fm-session-authority-exec.sh"
)
scoped_digest = hmac.new(scoped_key, body, hashlib.sha256).hexdigest()
if scoped_digest == root_digest:
    raise SystemExit("broker durable capability reused the primary root")
if scoped_key == broker.derive_broker_durable_key(
    root_key, task="beta", home="/test/home", launch_pid=42,
    launch_start="proc:x", launch_identity="exe:x",
    launch_script="/test/home/bin/fm-session-authority-exec.sh"
):
    raise SystemExit("broker durable capability was not task-bound")
if scoped_key == broker.derive_broker_durable_key(
    root_key, task="alpha", home="/test/other", launch_pid=42,
    launch_start="proc:x", launch_identity="exe:x",
    launch_script="/test/home/bin/fm-session-authority-exec.sh"
):
    raise SystemExit("broker durable capability was not home-bound")
if scoped_key == broker.derive_broker_durable_key(
    root_key, task="alpha", home="/test/home", launch_pid=99,
    launch_start="proc:y", launch_identity="exe:other",
    launch_script="/test/home/bin/fm-session-authority-exec.sh"
):
    raise SystemExit("broker durable capability did not rotate with launch generation")
PY
then
  fail "the broker durable capability was not scoped to validated launch identity"
fi
pass "peer-credential broker derives a scoped durable capability"

library_live=$(broker_library_hmac) \
  || fail "session-lock library did not adopt the peer-credential broker"
[ "${#library_live}" -eq 64 ] \
  || fail "session-lock library returned a malformed broker digest"
pass "session-lock library adopts the peer-credential authority channel"

kill "$BROKER_PID" 2>/dev/null || true
wait "$BROKER_PID" 2>/dev/null || true
BROKER_PID=
LONG_COMPONENT=home-$(printf '%080d' 0)
HOME_DIR="$TMP_ROOT/$LONG_COMPONENT"
STATE="$HOME_DIR/state"
RECORD="$STATE/.session-authority-broker"
LONG_SOCKET="$STATE/.session-authority-broker.sock"
mkdir -p "$STATE"
[ "${#LONG_SOCKET}" -ge 108 ] \
  || fail "long-home broker fixture did not exceed the Linux filesystem socket limit"
prepare_launch "$HOME_DIR"
start_broker
long_home_live=$(broker_hmac "$HOME_DIR" secondmate live) \
  || fail "same-home secondmate could not use authority from a long home"
[ "${#long_home_live}" -eq 64 ] \
  || fail "long-home authority broker returned a malformed digest"
pass "peer-credential broker supports homes beyond the filesystem socket path limit"
test_same_home_secondmate_rotation_uses_admission_capability

echo "# all fm-session-authority-broker tests passed"
