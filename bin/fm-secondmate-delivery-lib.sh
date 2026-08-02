#!/usr/bin/env bash

_FM_SECONDMATE_DELIVERY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_FM_SECONDMATE_DELIVERY_LIB_DIR/fm-pending-reply-lib.sh"

fm_secondmate_delivery_receipt_path() {
  local state=$1 namespace=$2 id=$3 generation=$4
  case "$namespace" in *[!A-Za-z0-9._-]*|'') return 1 ;; esac
  case "$id" in *[!A-Za-z0-9._-]*|'') return 1 ;; esac
  case "$generation" in *[!A-Za-z0-9._-]*|'') return 1 ;; esac
  if [ "$namespace" = update-nudge ]; then
    printf '%s/.secondmate-nudge-delivered/%s/%s' "$state" "$id" "$generation"
  else
    printf '%s/.secondmate-delivery/%s/%s/%s' "$state" "$namespace" "$id" "$generation"
  fi
}

fm_secondmate_delivery_receipt_write() {
  local receipt=$1 namespace=$2 id=$3 home=$4 target=$5 endpoint_generation=$6
  local generation=$7 provider_identity=$8 correlation=$9 message_signature=${10}
  local delivery_state=${11} parent tmp
  parent=${receipt%/*}
  mkdir -p "$parent" || return 1
  tmp=$(mktemp "$parent/.delivery.XXXXXX") || return 1
  {
    printf 'namespace=%s\n' "$namespace"
    printf 'id=%s\n' "$id"
    printf 'home=%s\n' "$home"
    printf 'target=%s\n' "$target"
    printf 'endpoint_generation=%s\n' "$endpoint_generation"
    printf 'generation=%s\n' "$generation"
    printf 'provider_identity=%s\n' "$provider_identity"
    printf 'correlation=%s\n' "$correlation"
    printf 'message_signature=%s\n' "$message_signature"
    printf 'state=%s\n' "$delivery_state"
  } > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$receipt" || {
    rm -f "$tmp"
    return 1
  }
}

fm_secondmate_delivery_receipt_read() {
  local receipt=$1 namespace=$2 id=$3 home=$4 target=$5 endpoint_generation=$6
  local generation=$7 provider_identity=$8 message_signature=$9 key
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  [ "$(wc -l < "$receipt" | tr -d ' ')" -eq 10 ] || return 1
  for key in namespace id home target endpoint_generation generation provider_identity correlation message_signature state; do
    [ "$(grep -c "^${key}=" "$receipt" 2>/dev/null || true)" -eq 1 ] || return 1
  done
  [ "$(sed -n 's/^namespace=//p' "$receipt")" = "$namespace" ] \
    && [ "$(sed -n 's/^id=//p' "$receipt")" = "$id" ] \
    && [ "$(sed -n 's/^home=//p' "$receipt")" = "$home" ] \
    && [ "$(sed -n 's/^target=//p' "$receipt")" = "$target" ] \
    && [ "$(sed -n 's/^endpoint_generation=//p' "$receipt")" = "$endpoint_generation" ] \
    && [ "$(sed -n 's/^generation=//p' "$receipt")" = "$generation" ] \
    && [ "$(sed -n 's/^provider_identity=//p' "$receipt")" = "$provider_identity" ] \
    && [ "$(sed -n 's/^message_signature=//p' "$receipt")" = "$message_signature" ] \
    || return 1
  FM_SECONDMATE_DELIVERY_CORRELATION=$(sed -n 's/^correlation=//p' "$receipt")
  FM_SECONDMATE_DELIVERY_STATE=$(sed -n 's/^state=//p' "$receipt")
  case "$FM_SECONDMATE_DELIVERY_CORRELATION" in
    *[!A-Fa-f0-9]*|'') return 1 ;;
  esac
  [ "${#FM_SECONDMATE_DELIVERY_CORRELATION}" -eq 16 ] || return 1
  case "$FM_SECONDMATE_DELIVERY_STATE" in
    prepared|confirmed-delivered|do-not-resend|finalizing|complete) ;;
    *) return 1 ;;
  esac
}

fm_secondmate_delivery_receipt_rewrite_state() {
  local receipt=$1 delivery_state=$2 namespace id home target endpoint_generation
  local generation provider_identity correlation message_signature
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  namespace=$(sed -n 's/^namespace=//p' "$receipt")
  id=$(sed -n 's/^id=//p' "$receipt")
  home=$(sed -n 's/^home=//p' "$receipt")
  target=$(sed -n 's/^target=//p' "$receipt")
  endpoint_generation=$(sed -n 's/^endpoint_generation=//p' "$receipt")
  generation=$(sed -n 's/^generation=//p' "$receipt")
  provider_identity=$(sed -n 's/^provider_identity=//p' "$receipt")
  correlation=$(sed -n 's/^correlation=//p' "$receipt")
  message_signature=$(sed -n 's/^message_signature=//p' "$receipt")
  fm_secondmate_delivery_receipt_read "$receipt" "$namespace" "$id" "$home" "$target" \
    "$endpoint_generation" "$generation" "$provider_identity" "$message_signature" \
    || return 1
  fm_secondmate_delivery_receipt_write "$receipt" "$namespace" "$id" "$home" "$target" \
    "$endpoint_generation" "$generation" "$provider_identity" "$correlation" \
    "$message_signature" "$delivery_state"
}

fm_secondmate_delivery_confirmed() {
  local state=$1 corr=$2 rec delivered
  fm_pending_reply_reconcile_delivery "$state" "$corr" >/dev/null 2>&1 || true
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ]
}

fm_secondmate_delivery_bound_correlation() {
  local state=$1 signature=$2 dir rec found=
  for dir in "$(fm_pending_reply_dir "$state")" \
    "$(fm_pending_reply_history_dir "$state")"; do
    [ -d "$dir" ] || continue
    for rec in "$dir"/[A-Fa-f0-9]*; do
      [ -f "$rec" ] && [ ! -L "$rec" ] || continue
      [ "$(fm_pending_reply_get "$rec" fm_delivery_transaction)" = "$signature" ] \
        || continue
      [ -z "$found" ] || return 2
      found=${rec##*/}
    done
  done
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

fm_secondmate_delivery_send_locked() {
  local state=$1 parent_home=$2 id=$3 home=$4 target=$5 endpoint_generation=$6
  local provider_identity=$7 namespace=$8 generation=$9 message=${10}
  local receipt message_signature transaction_signature corr out rc delivery_state rec marker binding_status
  local delivery_backend delivery_target
  fm_secondmate_lifecycle_identity_matches "$state" "$id" "$home" "$target" \
    "$endpoint_generation" "$provider_identity" || return 1
  delivery_backend=$FM_SECONDMATE_META_BACKEND
  delivery_target=$FM_SECONDMATE_META_TARGET
  message_signature=$(printf '%s' "$message" | cksum | awk '{printf "%s-%s", $1, $2}') || return 1
  transaction_signature=$(printf '%s' \
    "$namespace|$id|$home|$target|$endpoint_generation|$provider_identity|$generation|$message_signature" \
    | cksum | awk '{printf "%s-%s", $1, $2}') || return 1
  receipt=$(fm_secondmate_delivery_receipt_path "$state" "$namespace" "$id" "$generation") || return 1
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    fm_secondmate_delivery_receipt_read "$receipt" "$namespace" "$id" "$home" "$target" \
      "$endpoint_generation" "$generation" "$provider_identity" "$message_signature" || return 1
    corr=$FM_SECONDMATE_DELIVERY_CORRELATION
    delivery_state=$FM_SECONDMATE_DELIVERY_STATE
    if [ "$delivery_state" = finalizing ] || [ "$delivery_state" = complete ]; then
      FM_SECONDMATE_DELIVERY_RECEIPT=$receipt
      return 0
    fi
    rec=$(fm_pending_reply_path "$state" "$corr")
    [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ] \
      && [ "$(fm_pending_reply_get "$rec" fm_delivery_transaction)" = \
        "$transaction_signature" ] || return 1
    marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
    if fm_secondmate_delivery_confirmed "$state" "$corr"; then
      if [ "$delivery_state" = prepared ]; then
        fm_secondmate_delivery_receipt_write "$receipt" "$namespace" "$id" "$home" "$target" \
          "$endpoint_generation" "$generation" "$provider_identity" "$corr" \
          "$message_signature" confirmed-delivered || return 1
      fi
      FM_SECONDMATE_DELIVERY_RECEIPT=$receipt
      return 0
    elif [ -e "$marker" ] || [ -L "$marker" ]; then
      printf 'delivery is indeterminate for %s\n' "$target" >&2
      return 2
    fi
    [ "$delivery_state" = prepared ] || return 1
  else
    if corr=$(fm_secondmate_delivery_bound_correlation "$state" "$transaction_signature" 2>/dev/null); then
      :
    else
      binding_status=$?
      [ "$binding_status" -eq 1 ] || {
        printf 'delivery transaction binding is ambiguous for %s\n' "$target" >&2
        return 2
      }
      corr=$(fm_pending_reply_create "$parent_home" "$state" "$id" "$message") || return 1
      rec=$(fm_pending_reply_path "$state" "$corr")
      fm_pending_reply_set "$rec" fm_delivery_transaction "$transaction_signature" || return 1
    fi
    fm_secondmate_delivery_receipt_write "$receipt" "$namespace" "$id" "$home" "$target" \
      "$endpoint_generation" "$generation" "$provider_identity" "$corr" \
      "$message_signature" prepared || return 1
    fm_secondmate_delivery_send_locked "$@"
    return $?
  fi
  fm_pending_reply_prepare_delivery "$state" "$corr" || {
    rm -f "$receipt" || return 2
    fm_pending_reply_discard_undelivered "$state" "$corr" || return 2
    return 1
  }
  fm_secondmate_delivery_receipt_write "$receipt" "$namespace" "$id" "$home" "$target" \
    "$endpoint_generation" "$generation" "$provider_identity" "$corr" \
    "$message_signature" prepared || return 1
  fm_secondmate_lifecycle_identity_matches "$state" "$id" "$home" "$target" \
    "$endpoint_generation" "$provider_identity" || return 1
  out=$(FM_HOME="$parent_home" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-${FM_ROOT:-}}" \
    FM_STATE_OVERRIDE="$state" FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    FM_SEND_BOUND_BACKEND="$delivery_backend" \
    FM_SEND_BOUND_TARGET="$delivery_target" \
    "$_FM_SECONDMATE_DELIVERY_LIB_DIR/fm-send.sh" "fm-$id" "$message" 2>&1) \
    && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -Fq 'Do not resend' \
      && fm_secondmate_delivery_confirmed "$state" "$corr"; then
      delivery_state=do-not-resend
    else
      if printf '%s\n' "$out" | grep -Fq 'Do not resend'; then
        printf 'delivery is indeterminate for %s\n' "$target" >&2
        return 2
      fi
      rm -f "$receipt" || return 2
      fm_pending_reply_discard_undelivered "$state" "$corr" || return 2
      printf '%s\n' "${out%%$'\n'*}" >&2
      return 1
    fi
  else
    fm_secondmate_delivery_confirmed "$state" "$corr" || return 2
    delivery_state=confirmed-delivered
  fi
  fm_secondmate_delivery_receipt_write "$receipt" "$namespace" "$id" "$home" "$target" \
    "$endpoint_generation" "$generation" "$provider_identity" "$corr" \
    "$message_signature" "$delivery_state" || return 1
  fm_secondmate_lifecycle_identity_matches "$state" "$id" "$home" "$target" \
    "$endpoint_generation" "$provider_identity" || return 1
  # shellcheck disable=SC2034 # consumed by the caller after return.
  FM_SECONDMATE_DELIVERY_RECEIPT=$receipt
}

fm_secondmate_delivery_finish() {
  local receipt=$1
  [ -n "$receipt" ] || return 1
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    return 0
  fi
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  fm_secondmate_delivery_receipt_rewrite_state "$receipt" complete
}

fm_secondmate_delivery_finalize_update() {
  local receipt=$1 marker=$2 generation=$3 dir=$4 retry_marker=${5:-} selected
  fm_secondmate_delivery_receipt_rewrite_state "$receipt" finalizing || return 1
  if selected=$(fm_update_obligation_generation "$marker" "$dir" 2>/dev/null); then
    [ "$selected" = "$generation" ] || return 1
    fm_update_obligation_ack "$marker" "$generation" "$dir" || return 1
  elif fm_update_obligation_pending "$marker" "$dir"; then
    return 1
  fi
  if [ -n "$retry_marker" ]; then
    [ ! -e "$retry_marker" ] && [ ! -L "$retry_marker" ] \
      || fm_secondmate_delivery_finalize_marker "" "$retry_marker" || return 1
  fi
  fm_secondmate_delivery_finish "$receipt"
}

fm_secondmate_delivery_finalize_marker() {
  local receipt=$1 marker=$2
  [ -z "$receipt" ] \
    || fm_secondmate_delivery_receipt_rewrite_state "$receipt" finalizing || return 1
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    rm -f "$marker" || return 1
  fi
  [ -z "$receipt" ] || fm_secondmate_delivery_finish "$receipt"
}
