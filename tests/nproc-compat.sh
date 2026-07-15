#!/usr/bin/env bash

set -euo pipefail

clone="${NPROC_CLONE:-./nproc}"
gnu="${NPROC_GNU:-nproc}"
tmpdir="$(mktemp -d)"
tests=0
failures=0
skips=0

trap 'rm -rf "$tmpdir"' EXIT

run_capture() {
  local stem="$1"
  shift
  if "$@" >"$tmpdir/$stem.out" 2>"$tmpdir/$stem.err"; then
    printf '0\n' >"$tmpdir/$stem.rc"
  else
    printf '%s\n' "$?" >"$tmpdir/$stem.rc"
  fi
}

show_capture() {
  local stem="$1"
  printf 'stdout:\n'
  sed -n '1,20p' "$tmpdir/$stem.out"
  printf 'stderr:\n'
  sed -n '1,20p' "$tmpdir/$stem.err"
  printf 'rc=%s\n' "$(cat "$tmpdir/$stem.rc")"
}

record_failure() {
  local label="$1"
  printf 'FAIL: %s\n' "$label" >&2
  failures=$((failures + 1))
}

compare_count_case() {
  local label="$1"
  shift
  local -a prefix=()
  while [[ $# -gt 0 && $1 != -- ]]; do
    prefix+=("$1")
    shift
  done
  shift
  local -a args=("$@")

  tests=$((tests + 1))
  run_capture gnu "${prefix[@]}" "$gnu" "${args[@]}"
  run_capture clone "${prefix[@]}" "$clone" "${args[@]}"

  if ! cmp -s "$tmpdir/gnu.rc" "$tmpdir/clone.rc"; then
    record_failure "$label: exit status mismatch"
    show_capture gnu >&2
    show_capture clone >&2
    return
  fi

  if ! cmp -s "$tmpdir/gnu.out" "$tmpdir/clone.out"; then
    record_failure "$label: stdout mismatch"
    show_capture gnu >&2
    show_capture clone >&2
    return
  fi

  if ! cmp -s "$tmpdir/gnu.err" "$tmpdir/clone.err"; then
    record_failure "$label: stderr mismatch"
    show_capture gnu >&2
    show_capture clone >&2
  fi
}

compare_count_case_ignore_stderr() {
  local label="$1"
  shift
  local -a prefix=()
  while [[ $# -gt 0 && $1 != -- ]]; do
    prefix+=("$1")
    shift
  done
  shift
  local -a args=("$@")

  tests=$((tests + 1))
  run_capture gnu "${prefix[@]}" "$gnu" "${args[@]}"
  run_capture clone "${prefix[@]}" "$clone" "${args[@]}"

  if ! cmp -s "$tmpdir/gnu.rc" "$tmpdir/clone.rc"; then
    record_failure "$label: exit status mismatch"
    show_capture gnu >&2
    show_capture clone >&2
    return
  fi

  if ! cmp -s "$tmpdir/gnu.out" "$tmpdir/clone.out"; then
    record_failure "$label: stdout mismatch"
    show_capture gnu >&2
    show_capture clone >&2
  fi
}

compare_error_case() {
  local label="$1"
  local needle="$2"
  shift 2
  local -a prefix=()
  while [[ $# -gt 0 && $1 != -- ]]; do
    prefix+=("$1")
    shift
  done
  shift
  local -a args=("$@")

  tests=$((tests + 1))
  run_capture gnu "${prefix[@]}" "$gnu" "${args[@]}"
  run_capture clone "${prefix[@]}" "$clone" "${args[@]}"

  if ! cmp -s "$tmpdir/gnu.rc" "$tmpdir/clone.rc"; then
    record_failure "$label: exit status mismatch"
    show_capture gnu >&2
    show_capture clone >&2
    return
  fi

  if [[ -s "$tmpdir/clone.out" ]]; then
    record_failure "$label: clone wrote unexpected stdout"
    show_capture clone >&2
    return
  fi

  if ! grep -Fq "$needle" "$tmpdir/gnu.err"; then
    record_failure "$label: GNU stderr did not contain '$needle'"
    show_capture gnu >&2
    return
  fi

  if ! grep -Fq "$needle" "$tmpdir/clone.err"; then
    record_failure "$label: clone stderr did not contain '$needle'"
    show_capture clone >&2
  fi
}

check_mode_case() {
  local label="$1"
  local needle="$2"
  shift 2
  local -a args=("$@")

  tests=$((tests + 1))
  run_capture gnu "$gnu" "${args[@]}"
  run_capture clone "$clone" "${args[@]}"

  if ! cmp -s "$tmpdir/gnu.rc" "$tmpdir/clone.rc"; then
    record_failure "$label: exit status mismatch"
    show_capture gnu >&2
    show_capture clone >&2
    return
  fi

  if ! grep -Fq "$needle" "$tmpdir/clone.out"; then
    record_failure "$label: clone stdout missing '$needle'"
    show_capture clone >&2
    return
  fi

  if [[ -s "$tmpdir/clone.err" ]]; then
    record_failure "$label: clone wrote unexpected stderr"
    show_capture clone >&2
  fi
}

compare_count_case "default" --
compare_count_case "all" -- --all
compare_count_case "ignore-equals" -- --ignore=2
compare_count_case "ignore-plus" -- --ignore=+2
compare_count_case "ignore-zero" -- --ignore=0
compare_count_case "ignore-separate" -- --ignore 2
compare_count_case "ignore-leading-space" -- "--ignore= 2"
compare_count_case "omp-num" env OMP_NUM_THREADS=2 --
compare_count_case "omp-limit" env OMP_THREAD_LIMIT=2 --
compare_count_case "omp-both" env OMP_NUM_THREADS=8 OMP_THREAD_LIMIT=2 --
compare_count_case "omp-comma" env OMP_NUM_THREADS=2,4 --
compare_count_case "omp-ws" env "OMP_NUM_THREADS= 2 " --
compare_count_case "omp-zero" env OMP_NUM_THREADS=0 --
compare_count_case "all-ignores-env" env OMP_NUM_THREADS=2 -- --all

if command -v taskset >/dev/null 2>&1; then
  compare_count_case "affinity-taskset" taskset -c 0-1 --
else
  printf 'SKIP: affinity-taskset (taskset unavailable)\n' >&2
  skips=$((skips + 1))
fi

compare_error_case "extra-operand" "extra operand" -- foo
compare_error_case "extra-operand-after-option" "extra operand" -- foo --all
compare_error_case "end-of-options" "extra operand" -- -- --help
compare_error_case "unknown-option" "unrecognized option" -- --bogus
compare_error_case "missing-ignore-arg" "requires an argument" -- --ignore
compare_error_case "invalid-ignore-abc" "invalid number" -- --ignore=abc
compare_error_case "invalid-ignore-neg" "invalid number" -- --ignore=-1
compare_error_case "invalid-ignore-endopts" "invalid number" -- --ignore --

check_mode_case "help-with-tail" "Usage: nproc" --help foo
check_mode_case "help-after-operand" "Usage: nproc" foo --help
check_mode_case "version-with-tail" "GNU-compatible nproc" --version foo
check_mode_case "version-after-operand" "GNU-compatible nproc" foo --version

if command -v systemd-run >/dev/null 2>&1 && \
   systemd-run --user --wait --pipe -p CPUQuota=25% "$gnu" >/dev/null 2>/dev/null; then
  compare_count_case_ignore_stderr "quota-25-percent" systemd-run --user --wait --pipe -p CPUQuota=25% --
else
  printf 'SKIP: quota-25-percent (systemd-run unavailable or user bus denied)\n' >&2
  skips=$((skips + 1))
fi

if (( failures > 0 )); then
  printf 'nproc compatibility checks: %s/%s failed, %s skipped\n' \
    "$failures" "$tests" "$skips" >&2
  exit 1
fi

printf 'nproc compatibility checks: %s passed, %s skipped\n' "$tests" "$skips"
