#!/bin/bash
set -u
export ZENSU_BASH_START="${ZENSU_BASH_START:-}"
: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/../.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

case "${1:-}" in
  --phase)
    phase_val=""
    step_val=""
    session_val=""
    reason_val=""
    # Kiro delta: value-consuming options fail fast when the value is missing
    # (bash leaves params unchanged when `shift 2` exceeds $#, so the loop
    # would otherwise spin forever and hang the model's shell tool).
    while [ $# -gt 0 ]; do
      case "$1" in
        --phase|--step|--session|--reason)
          [ $# -ge 2 ] || { echo "zensu-log.sh: $1 needs a value" >&2; exit 2; }
          case "$1" in
            --phase)   phase_val="$2" ;;
            --step)    step_val="$2" ;;
            --session) session_val="$2" ;;
            --reason)  reason_val="$2" ;;
          esac
          shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -z "$phase_val" ]; then
      echo "zensu-log.sh --phase requires a phase value" >&2
      exit 2
    fi
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 --phase $phase_val --step $step_val}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    tdd_write_phase "$session_val" "$step_val" "$phase_val" "$reason_val"
    exit $?
    ;;
  --mode)
    session_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session)
          [ $# -ge 2 ] || { echo "zensu-log.sh: $1 needs a value" >&2; exit 2; }
          session_val="$2"
          shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 --mode}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    if [ "$(tdd_vanilla_mode "$(tdd_state_file "$session_val")")" = "true" ]; then
      echo "vanilla"
    else
      echo "strict"
    fi
    exit 0
    ;;
  --tdd-begin|--tdd-complete|--chain-done|--code-review-done|--self-review-fixed|--tdd-reset|--workflow-begin|--workflow-end)
    verb="$1"
    session_val=""
    tools_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session|--tools)
          [ $# -ge 2 ] || { echo "zensu-log.sh: $1 needs a value" >&2; exit 2; }
          case "$1" in
            --session) session_val="$2" ;;
            --tools)   tools_val="$2" ;;
          esac
          shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 $verb}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    case "$verb" in
      --tdd-begin)
        # Freeze the implementation mode for THIS session (upstream-synced):
        # hooks.tddImplementation is read ONCE here and persisted into the
        # state file's `vanilla` flag — the gate and the post-review hook read
        # only the state flag, so config flips mid-session change nothing.
        # Written unconditionally in BOTH directions so a re-begin under
        # changed config re-freezes from the then-current value. The freeze
        # lands BEFORE the active flag and a freeze-write failure ABORTS
        # activation: the gate must never observe an armed session carrying a
        # stale mode.
        if zensu_hook_enabled tddImplementation; then
          want_vanilla=false
        else
          want_vanilla=true
        fi
        if ! tdd_set_flag "$session_val" vanilla "$want_vanilla"; then
          echo "zensu-log --tdd-begin: mode freeze write failed — session NOT activated" >&2
          tdd_set_flag "$session_val" active false 2>/dev/null || true
          tdd_begin_rc=1
        else
          tdd_set_flag "$session_val" active true
          tdd_begin_rc=$?
          if [ "$tdd_begin_rc" -eq 0 ]; then
            if [ "$(tdd_vanilla_mode "$(tdd_state_file "$session_val")")" = "true" ]; then
              echo "mode: vanilla"
            else
              echo "mode: strict"
            fi
          else
            echo "zensu-log --tdd-begin: active flag write failed — session NOT activated" >&2
            tdd_set_flag "$session_val" active false 2>/dev/null || true
          fi
        fi
        # Kiro delta (upstream-sync candidate, documented in AGENTS.md): a NEW
        # chain in the SAME session must re-arm the Stop backstop — clear the
        # previous chain's terminal flags and its consumed stop-block budget,
        # or the enforcer no-ops for every chain after the first. Gated on a
        # SUCCESSFUL begin: a failed (re-)begin must not half-reset the
        # previous chain's state while that chain stays armed.
        if [ "$tdd_begin_rc" -eq 0 ]; then
          tdd_set_flag "$session_val" implComplete false
          tdd_set_flag "$session_val" chainDone false
          tdd_set_flag "$session_val" codeReviewDone false
          tdd_set_flag "$session_val" selfReviewFixed false
          stopblocks_file="$(tdd_state_file "$session_val").stopblocks"
          stopblocks_dir="$(dirname "$stopblocks_file")"
          if [ -L "$stopblocks_file" ] || [ -L "$stopblocks_dir" ] || [ -L "${CLAUDE_PROJECT_DIR:-.}/.zensu" ]; then
            echo "zensu-log --tdd-begin: refusing stop-budget reset through symlinked path — NOT reset" >&2
          else
            rm -f -- "$stopblocks_file"
          fi
          rounds_counter_file="$(zensu_rounds_counter_file "$session_val")"
          rounds_state_dir="$(dirname "$rounds_counter_file")"
          if [ -L "${CLAUDE_PROJECT_DIR:-.}/.zensu" ]; then
            echo "zensu-log --tdd-begin: refusing resets under symlinked .zensu — NOT reset" >&2
          elif [ -L "$rounds_counter_file" ]; then
            echo "zensu-log --tdd-begin: refusing to delete through symlink at $rounds_counter_file — rounds counter NOT reset" >&2
          elif [ -L "$rounds_state_dir" ]; then
            echo "zensu-log --tdd-begin: refusing to reset under symlinked state dir $rounds_state_dir — rounds counter NOT reset" >&2
          else
            rm -f -- "$rounds_counter_file"
          fi
        fi
        exit "$tdd_begin_rc"
        ;;
      --tdd-complete) tdd_set_flag "$session_val" implComplete true ;;
      --chain-done)   tdd_set_flag "$session_val" chainDone true ;;
      --code-review-done)  tdd_set_flag "$session_val" codeReviewDone true ;;
      --self-review-fixed) tdd_set_flag "$session_val" selfReviewFixed true ;;
      --workflow-begin)
        tdd_workflow_begin "$session_val" "$tools_val"
        ;;
      --workflow-end)   tdd_set_flag "$session_val" workflowActive false ;;
      --tdd-reset)    tdd_clear_session "$session_val" ;;
    esac
    exit $?
    ;;
esac

cmd="${1:-timestamp}"
case "$cmd" in
  timestamp)
    start="${2:-$(date +%s)}"
    case "$start" in
      ''|*[!0-9]*) start=$(date +%s) ;;
    esac
    style=$(_zensu_log_style)
    case "$style" in
      none)
        printf ""
        ;;
      relative)
        now=$(date +%s)
        diff=$((now - 10#$start))
        [ "$diff" -lt 0 ] && diff=0
        if [ "$diff" -lt 86400 ]; then
          printf "[+%02d:%02d:%02d] " $((diff/3600)) $(((diff%3600)/60)) $((diff%60))
        else
          days=$((diff/86400))
          rem=$((diff%86400))
          printf "[+%dd %02d:%02d:%02d] " "$days" $((rem/3600)) $(((rem%3600)/60)) $((rem%60))
        fi
        ;;
      *)
        printf "[%s] " "$(date +%H:%M:%S)"
        ;;
    esac
    ;;
  style)
    _zensu_log_style
    ;;
  *)
    echo "usage: zensu-log.sh {timestamp <epoch> | style}" >&2
    exit 2
    ;;
esac
