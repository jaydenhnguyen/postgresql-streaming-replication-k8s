#!/bin/bash
set -euo pipefail

STATUS=/home/ec2-user/user-data-status.txt
LOG=/var/log/user-data.log
: >"$STATUS"
: >"$LOG"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG" "$STATUS"; }
trap 'log "FAILED at line $LINENO: ${BASH_COMMAND} (exit $?)"; exit 1' ERR

log "bootstrap start"
KIND_VERSION="v0.32.0"
REPO_URL="https://github.com/jaydenhnguyen/postgresql-streaming-replication-k8s.git"
REPO_DIR="/home/ec2-user/postgresql-streaming-replication-k8s"
READY_MARKER="/var/lib/cloud/instance/kind-host-ready"

case "$(uname -m)" in
  x86_64)  KARCH="amd64" ;;
  aarch64) KARCH="arm64" ;;
  *) log "unsupported arch: $(uname -m)"; exit 1 ;;
esac

# Wait for outbound HTTPS (Academy / slow DHCP)
for i in $(seq 1 60); do
  if curl -fsSIL --max-time 5 https://github.com >/dev/null 2>&1; then
    log "network ok"
    break
  fi
  log "waiting for network ($i/60)"
  sleep 2
done

log "sudo dnf install docker git gettext jq"
sudo dnf install -y docker git gettext jq

log "starting docker"
systemctl enable --now docker
usermod -aG docker ec2-user

log "installing kubectl"
curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

log "installing kind ${KIND_VERSION}"
curl -fsSL -o /usr/local/bin/kind \
  "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${KARCH}"
chmod +x /usr/local/bin/kind

log "cloning repo"
if [[ -d "${REPO_DIR}/.git" ]]; then
  runuser -u ec2-user -- git -C "${REPO_DIR}" pull --ff-only
else
  rm -rf "${REPO_DIR}"
  runuser -u ec2-user -- git clone "${REPO_URL}" "${REPO_DIR}"
fi
chown -R ec2-user:ec2-user "${REPO_DIR}"

docker --version | tee -a "$LOG" "$STATUS"
kubectl version --client | tee -a "$LOG" "$STATUS"
kind version | tee -a "$LOG" "$STATUS"
command -v envsubst
test -f "${REPO_DIR}/src/bootstrap.sh"

# Permanent shell alias for ec2-user
if ! grep -qxF 'alias kb=kubectl' /home/ec2-user/.bashrc 2>/dev/null; then
  echo 'alias kb=kubectl' >> /home/ec2-user/.bashrc
fi
chown ec2-user:ec2-user /home/ec2-user/.bashrc

touch "${READY_MARKER}"
chown ec2-user:ec2-user "$STATUS"
log "bootstrap done - repo at ${REPO_DIR}"
