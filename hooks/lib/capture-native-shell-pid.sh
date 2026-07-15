#!/bin/bash
# Return the native operating-system PID of the shell that sourced this file.
# Git Bash exposes a separate MSYS PID in $$; native Node must instead receive
# the corresponding Windows PID when it validates lock ownership.

zensu_capture_native_shell_pid() { # $1=output file
  local output_file="$1" native_pid=""
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      [ -r "/proc/$$/winpid" ] || return 1
      IFS= read -r native_pid < "/proc/$$/winpid" || return 1
      ;;
    *) native_pid="$$" ;;
  esac
  case "$native_pid" in ''|*[!0-9]*) return 1 ;; esac
  node -e '
    try { process.kill(Number(process.argv[1]), 0); }
    catch (error) { if (!error || error.code !== "EPERM") process.exit(1); }
  ' "$native_pid" >/dev/null 2>&1 || return 1
  printf '%s\n' "$native_pid" > "$output_file"
}
