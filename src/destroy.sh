#!/usr/bin/env bash
# Tear down kind cluster + bootstrap temp artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ROOT}/.." && pwd)"
cd "$ROOT"

STATE_FILE="${ROOT}/.bootstrap-state"   # written by bootstrap.sh

# Print paths relative to project root (or short form for /tmp).
rel() {
  local p="$1"
  if [[ "$p" == "${REPO_ROOT}/"* ]]; then
    printf '%s' "${p#"${REPO_ROOT}/"}"
  elif [[ "$p" == "${ROOT}/"* ]]; then
    printf 'src/%s' "${p#"${ROOT}/"}"
  else
    printf '.../%s' "$(basename "$p")"
  fi
}

# Colors only when stdout is a terminal.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_DIM=$'\033[2m'
else
  C_RESET= C_BOLD= C_CYAN= C_GREEN= C_YELLOW= C_RED= C_DIM=
fi

step() {
  local msg="$*"
  local line
  line="$(printf '─%.0s' {1..56})"
  printf '\n%s%s%s\n' "${C_CYAN}${C_BOLD}" "┌${line}┐" "${C_RESET}"
  printf '%s%s%s\n' "${C_CYAN}${C_BOLD}" "│  ▶ ${msg}" "${C_RESET}"
  printf '%s%s%s\n' "${C_CYAN}${C_BOLD}" "└${line}┘" "${C_RESET}"
}

# Flush-left; ---- separates process output from bootstrap status.
sep()  { printf '%s----%s\n' "${C_DIM}" "${C_RESET}"; }
ok()   { sep; printf '%s✓ %s%s\n' "${C_GREEN}" "$*" "${C_RESET}"; }
info() { printf '%s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
warn() { printf '%s! %s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"; }

step "Loading control env vars"
# Defaults; .bootstrap-state and CLI can override.
STUDENT_ID="${1:-${STUDENT_ID:-hdhnguyen}}"
CLUSTER_NAME="${CLUSTER_NAME:-pg-replication}"
GEN="${GEN:-}"

# Restore GEN path / names from last bootstrap (no passwords in this file).
if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  ok "sourced $(rel "${STATE_FILE}")"
fi

# Explicit CLI student id wins over state file.
if [[ -n "${1:-}" ]]; then
  STUDENT_ID="$1"
fi

export STUDENT_ID CLUSTER_NAME
info "STUDENT_ID=${STUDENT_ID}"
info "CLUSTER_NAME=${CLUSTER_NAME}"
if [[ -n "${GEN}" ]]; then
  info "GEN=$(rel "${GEN}")"
else
  info "GEN=<none>"
fi

step "Deleting kind cluster ${CLUSTER_NAME}"
if command -v kind >/dev/null 2>&1; then
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    ok "cluster deleted"
  else
    warn "cluster ${CLUSTER_NAME} not found — skip"
  fi
else
  warn "kind not installed — skip cluster delete"
fi

step "Removing temp prepared-manifests directory"
if [[ -n "${GEN}" && -d "${GEN}" ]]; then
  rm -rf "${GEN}"
  ok "removed $(rel "${GEN}")"
else
  info "no GEN directory to remove"
fi

step "Removing bootstrap state file"
if [[ -f "${STATE_FILE}" ]]; then
  rm -f "${STATE_FILE}"
  ok "removed $(rel "${STATE_FILE}")"
else
  info "no state file present"
fi

step "Clearing credential env vars in this process"
unset POSTGRES_PASSWORD REPLICATION_PASSWORD GEN || true
ok "unset POSTGRES_PASSWORD REPLICATION_PASSWORD GEN"
info "./destroy.sh cannot clear vars in your parent shell"
info ".env is left alone (delete manually if you want)"

step "Destroy complete"
printf '%s%s%s\n' "${C_GREEN}${C_BOLD}" "Done." "${C_RESET}"
