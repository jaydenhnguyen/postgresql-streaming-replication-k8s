#!/usr/bin/env bash
# Local kind bootstrap: primary + standby streaming replication.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ROOT}/.." && pwd)"
cd "$ROOT"

# Task 9: student ID from $1 or STUDENT_ID (required - no silent hardcode for grading).
if [[ -n "${1:-}" ]]; then
  STUDENT_ID="$1"
elif [[ -n "${STUDENT_ID:-}" ]]; then
  :
else
  echo "Usage: ./bootstrap.sh <studentID>" >&2
  echo "   or: STUDENT_ID=<id> ./bootstrap.sh" >&2
  exit 1
fi

CLUSTER_NAME="${CLUSTER_NAME:-pg-replication}"
NS="pg-${STUDENT_ID}"
PRIMARY_POD="pg-primary-${STUDENT_ID}-0"
STANDBY_POD="pg-standby-${STUDENT_ID}-0"
STATE_FILE="${ROOT}/.bootstrap-state"   # non-secret paths for destroy.sh
CREDS_FILE="${ROOT}/.env"               # local passwords (gitignored)

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

# Boxed step header (easy to scan in long output).
step() {
  local msg="$*"
  local line
  line="$(printf '─%.0s' {1..56})"
  printf '\n%s%s%s\n' "${C_CYAN}${C_BOLD}" "┌${line}┐" "${C_RESET}"
  printf '%s%s%s\n' "${C_CYAN}${C_BOLD}" "│  ▶ ${msg}" "${C_RESET}"
  printf '%s%s%s\n' "${C_CYAN}${C_BOLD}" "└${line}┘" "${C_RESET}"
}

sep()  { printf '%s----%s\n' "${C_DIM}" "${C_RESET}"; }
ok()   { sep; printf '%s✓ %s%s\n' "${C_GREEN}" "$*" "${C_RESET}"; }
info() { printf '%s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
warn() { printf '%s! %s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"; }
die()  { printf '%s✗ %s%s\n' "${C_RED}" "$*" "${C_RESET}" >&2; exit 1; }

# Fail fast if a required binary is missing.
need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

elapsed() {
  local now
  now="$(date +%s)"
  echo "$((now - BOOTSTRAP_START))s"
}

step "Checking prerequisites"
need kind
need kubectl
need envsubst
need openssl
need mktemp
need docker
info "student id : ${STUDENT_ID}"
info "namespace  : ${NS}"
info "cluster    : ${CLUSTER_NAME}"
ok "tools present"

step "Loading credentials"
# Prefer .env; otherwise generate random passwords for this run.
if [[ -f "${CREDS_FILE}" ]]; then
  set -a                          # auto-export sourced vars
  # shellcheck disable=SC1090
  source "${CREDS_FILE}"
  set +a
  ok "loaded $(rel "${CREDS_FILE}")"
else
  warn "no $(rel "${CREDS_FILE}") - copy .env.example → .env or passwords will be random"
fi

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)}"
export STUDENT_ID POSTGRES_PASSWORD REPLICATION_PASSWORD
[[ -n "${POSTGRES_PASSWORD}" ]] || die "POSTGRES_PASSWORD is empty"
[[ -n "${REPLICATION_PASSWORD}" ]] || die "REPLICATION_PASSWORD is empty"
ok "credentials ready (values not printed)"

step "Creating temp directory for prepared manifests"
GEN="$(mktemp -d)"                # filled-in YAML lives here (not in git)
info "GEN=$(rel "${GEN}")"

# Save non-secret paths so destroy.sh can clean up.
cat >"${STATE_FILE}" <<EOF
STUDENT_ID=${STUDENT_ID}
CLUSTER_NAME=${CLUSTER_NAME}
GEN=${GEN}
EOF
ok "wrote $(rel "${STATE_FILE}")"

step "Preparing manifests (fill in student id + passwords)"
# Only replace these three vars (keeps ${PRIMARY_HOST} etc. in scripts).
while IFS= read -r -d '' f; do
  rel_f="${f#./}"
  mkdir -p "${GEN}/$(dirname "${rel_f}")"
  envsubst '${STUDENT_ID} ${POSTGRES_PASSWORD} ${REPLICATION_PASSWORD}' \
    <"${rel_f}" \
    >"${GEN}/${rel_f}"
  info "prepared ${rel_f}"
done < <(find manifests -type f -name '*.yaml' -print0 | sort -z)
ok "all manifests prepared"

step "Creating kind cluster"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "cluster ${CLUSTER_NAME} already exists - skip create"
else
  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
  ok "cluster created"
fi
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
ok "kubectl context ready"

# Apply one prepared file from GEN.
apply() {
  local path="$1"
  info "kubectl apply -f ${path}"
  kubectl apply -f "${GEN}/${path}"
}

step "Applying namespace / ConfigMaps / Secret / Services"
apply manifests/namespace.yaml
apply manifests/config/secret.yaml
apply manifests/config/configmap.yaml
apply manifests/config/scripts-configmap.yaml
apply manifests/services/pg-primary-headless.yaml
apply manifests/services/pg-standby-headless.yaml
apply manifests/services/pg-write.yaml
ok "base resources applied"

step "Applying primary StatefulSet"
apply manifests/statefulsets/pg-primary.yaml
ok "primary StatefulSet applied"

step "Waiting for primary Ready"
kubectl rollout status "statefulset/pg-primary-${STUDENT_ID}" -n "${NS}" --timeout=300s
kubectl wait --for=condition=Ready "pod/${PRIMARY_POD}" -n "${NS}" --timeout=300s
kubectl get pods,pvc -n "${NS}" -o wide
ok "primary is Ready"

step "Ensuring the replication role 'repl' on primary DB (Task 4)"
# TCP localhost → pg_hba trust; password from env (same as Secret).
kubectl exec -n "${NS}" "${PRIMARY_POD}" -- \
  psql -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'repl') THEN
    CREATE ROLE repl WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';
  ELSE
    ALTER ROLE repl WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';
  END IF;
END
\$\$;"
ok "role repl ready"

step "Applying standby StatefulSet (initContainer pg_basebackup)"
apply manifests/statefulsets/pg-standby.yaml
ok "standby StatefulSet applied"

step "Waiting for standby Ready"
kubectl rollout status "statefulset/pg-standby-${STUDENT_ID}" -n "${NS}" --timeout=600s
kubectl wait --for=condition=Ready "pod/${STANDBY_POD}" -n "${NS}" --timeout=600s
kubectl get pods,pvc -n "${NS}" -o wide
ok "standby is Ready"

# Task 6 schema: events_<id>(id serial, tag text, created_at timestamptz default now())
step "Seed (1/3) - create database clo835"
kubectl exec -n "${NS}" "${PRIMARY_POD}" -- \
  psql -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE clo835;" 2>/dev/null \
  || info "database clo835 already exists"
ok "database clo835 ready"

step "Seed (2/3) - create table events_${STUDENT_ID}"
kubectl exec -n "${NS}" "${PRIMARY_POD}" -- \
  psql -h localhost -U postgres -d clo835 -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE IF NOT EXISTS events_${STUDENT_ID} (
        id          bigserial PRIMARY KEY,
        created_at  timestamptz NOT NULL DEFAULT now(),
        tag         text        NOT NULL,
        payload     text
      );"
ok "table events_${STUDENT_ID} ready"

step "Seed (3/3) - insert ≥20 rows"
kubectl exec -n "${NS}" "${PRIMARY_POD}" -- \
  psql -h localhost -U postgres -d clo835 -v ON_ERROR_STOP=1 \
  -c "INSERT INTO events_${STUDENT_ID} (tag, payload)
      SELECT 'student-${STUDENT_ID}', 'seed-row-' || g
      FROM generate_series(1, 20) AS g
      WHERE NOT EXISTS (SELECT 1 FROM events_${STUDENT_ID} LIMIT 1);
      SELECT COUNT(*) AS seed_rows FROM events_${STUDENT_ID};"
ok "seed data ready"

step "Verifying streaming replication"
info "primary - pg_stat_replication"
kubectl exec -n "${NS}" "${PRIMARY_POD}" -- \
  psql -h localhost -U postgres -d postgres -c \
  "SELECT application_name, state, sync_state, replay_lsn,
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
   FROM pg_stat_replication;"
ok "primary replication check done"

info "standby - recovery flag + row count"
kubectl exec -n "${NS}" "${STANDBY_POD}" -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT pg_is_in_recovery() AS in_recovery;
   SELECT COUNT(*) AS events_${STUDENT_ID}_rows FROM events_${STUDENT_ID};"
ok "standby check done"

step "Bootstrap complete"
ok "Namespace : ${NS}"
ok "Primary   : ${PRIMARY_POD}"
ok "Standby   : ${STANDBY_POD}"
info "GEN       : $(rel "${GEN}")"
info "Secret    : pg-creds-${STUDENT_ID} (in-cluster)"
info "Tear down : ./destroy.sh ${STUDENT_ID}"

step "Healthy cluster summary"
kubectl get pods,pvc -n "${NS}" -o wide
ok "bootstrap healthy in $(elapsed) (target < 15 min)"

step "Copy-paste commands"
cat <<EOF

# Shell into pods
kubectl exec -it -n ${NS} ${PRIMARY_POD} -- bash
kubectl exec -it -n ${NS} ${STANDBY_POD} -- bash

# psql (inside a pod, or via kubectl exec)
kubectl exec -it -n ${NS} ${PRIMARY_POD} -- psql -h localhost -U postgres -d clo835
kubectl exec -it -n ${NS} ${STANDBY_POD} -- psql -h localhost -U postgres -d clo835

# Once already inside bash on a pod:
psql -h localhost -U postgres -d clo835

# Task 7 - streaming check
kubectl exec -n ${NS} ${PRIMARY_POD} -- \\
  psql -h localhost -U postgres -c "SELECT state, sync_state, replay_lsn FROM pg_stat_replication;"

# Task 11 - lag check (side by side)
echo "primary LSN:"; kubectl exec -n ${NS} ${PRIMARY_POD} -- \\
  psql -h localhost -U postgres -Atq -c "SELECT pg_current_wal_lsn();"
echo "standby replay LSN:"; kubectl exec -n ${NS} ${STANDBY_POD} -- \\
  psql -h localhost -U postgres -Atq -c "SELECT pg_last_wal_replay_lsn();"
kubectl exec -n ${NS} ${PRIMARY_POD} -- psql -h localhost -U postgres -c "\\
  SELECT pg_current_wal_lsn() AS primary_lsn,\\
         replay_lsn AS standby_replay_lsn,\\
         pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes\\
  FROM pg_stat_replication;"

# Seed peek (your ID in tags)
kubectl exec -n ${NS} ${PRIMARY_POD} -- \\
  psql -h localhost -U postgres -d clo835 -c "SELECT * FROM events_${STUDENT_ID} LIMIT 5;"

# Tear down
./destroy.sh ${STUDENT_ID}

EOF

printf '%s%s%s\n' "${C_GREEN}${C_BOLD}" "Done." "${C_RESET}"
