#!/usr/bin/env bash
# Compatibility helpers for real-Herdr tests. Production safety lives in
# bin/fm-herdr-lab.sh; these names keep smoke/e2e tests concise.
set -u

export FM_GATE_REFUSE_BYPASS=1
HERDR_TEST_SAFETY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_ROOT/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { fm_herdr_lab_refuse_if_default "$1"; }
herdr_safe_stop_and_delete() { fm_herdr_lab_teardown "$1"; }
