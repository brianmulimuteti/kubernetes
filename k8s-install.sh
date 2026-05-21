#!/usr/bin/env bash
# =============================================================================
#  k8s-install.sh
#  ---------------------------------------------------------------------------
#  One-shot installer for a kubeadm-based Kubernetes cluster on:
#    - Ubuntu 22.04+ / Debian 12+
#    - Amazon Linux 2 / 2023, RHEL 8+/9+, Rocky, Alma, CentOS Stream, Fedora
#  Run the SAME script on every node; pass a ROLE flag to tell it
#  whether the node is the control plane or a worker.
#
#  Tested versions (May 2026, all latest stable at time of writing):
#    - Kubernetes      v1.34   (kubeadm/kubelet/kubectl 1.34.x)
#    - containerd      v2.3.0  (LTS)
#    - runc            v1.4.0
#    - CNI plugins     v1.9.1
#    - Calico          v3.32.0
#
#  Usage:
#    sudo ./k8s-install.sh prep                                     # both: common prep
#    sudo ./k8s-install.sh init   [--node-name master-1]            # control plane
#                                 [--apiserver-address <IP>]
#    sudo ./k8s-install.sh join   [--node-name worker-N] \
#                                 "<full kubeadm join cmd>"         # workers
#    sudo ./k8s-install.sh label-workers                            # control plane
#    sudo ./k8s-install.sh all-in-one [--node-name lab-1]           # single-node
#
#  Custom node names (--node-name):
#    * Optional. If omitted, the EC2/cloud hostname (e.g. ip-172-31-39-67) is used.
#    * MUST be lowercase RFC 1123 (a-z, 0-9, dashes; no underscores or dots).
#    * MUST be unique across the cluster. Using worker-1 on two nodes will break.
#    * Survives reboot: the script disables cloud-init's hostname management.
#
#  After `init` finishes it prints the join command; copy it and run
#  `sudo ./k8s-install.sh join "<paste>"` on every worker (with a unique
#  --node-name per worker if you want pretty names).
#
#  After all workers have joined, run on the CONTROL PLANE:
#    sudo ./k8s-install.sh label-workers
#  …which adds the `worker` role label so `kubectl get nodes` shows ROLES=worker.
#
#  Token expired? (kubeadm join tokens live for 24 hours by default.)
#  On the CONTROL PLANE node, generate a fresh one:
#
#    sudo kubeadm token create --print-join-command
#
#  …then paste its output into the `join` command above.
# =============================================================================

set -Eeuo pipefail

# ---------- pinned versions (bump here when you want to upgrade) -------------
K8S_MINOR="1.34"                    # apt repo channel
K8S_PKG_VERSION="1.34.8-1.1"        # exact deb package version (kubeadm/kubelet/kubectl)
CONTAINERD_VERSION="2.3.0"
RUNC_VERSION="1.4.0"
CNI_PLUGINS_VERSION="1.9.1"
CRICTL_VERSION="1.34.0"             # match Kubernetes minor for best CRI compatibility
CALICO_VERSION="v3.32.0"
POD_CIDR="192.168.0.0/16"           # must match the CNI manifest below
# -----------------------------------------------------------------------------

# Architecture (portable; works on Debian/Ubuntu/RHEL/Amazon Linux/Fedora).
case "$(uname -m)" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l)  ARCH="arm"   ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

# OS family detection.  OS_FAMILY is "debian" or "rhel".
# (Amazon Linux 2/2023, RHEL, Rocky, Alma, CentOS Stream, Fedora -> "rhel")
detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID_LIKE:-} ${ID:-}" in
      *debian*|*ubuntu*) OS_FAMILY="debian" ;;
      *rhel*|*fedora*|*centos*|*amzn*) OS_FAMILY="rhel" ;;
      *)
        # Fall back to package-manager probe.
        if   command -v apt-get >/dev/null; then OS_FAMILY="debian"
        elif command -v dnf      >/dev/null; then OS_FAMILY="rhel"
        elif command -v yum      >/dev/null; then OS_FAMILY="rhel"
        else echo "unsupported distro: ${ID:-unknown}" >&2; exit 1
        fi ;;
    esac
  else
    echo "/etc/os-release not found; cannot detect distro" >&2; exit 1
  fi
}
detect_os

LOG_PREFIX="[k8s-install]"

log()  { echo -e "\033[1;32m${LOG_PREFIX}\033[0m $*"; }
warn() { echo -e "\033[1;33m${LOG_PREFIX} WARN:\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m${LOG_PREFIX} ERROR:\033[0m $*" >&2; exit 1; }

trap 'die "failed at line $LINENO (exit $?)"' ERR

require_root() {
  [[ $EUID -eq 0 ]] || die "run as root (use sudo)"
}

# -----------------------------------------------------------------------------
# 1. Common prep: kernel modules, sysctl, swap off, container runtime, kube*
# -----------------------------------------------------------------------------
prep_node() {
  require_root
  log "Disabling swap (kubelet requires it)…"
  swapoff -a
  sed -i.bak '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab

  log "Loading kernel modules overlay & br_netfilter…"
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  log "Setting sysctl params for Kubernetes networking…"
  cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  # Only apply our file, not every other one in /etc/sysctl.d/. On Amazon
  # Linux 2023 other files reference per-interface knobs that don't exist
  # yet at boot, which clutters the output with harmless warnings.
  sysctl -p /etc/sysctl.d/k8s.conf >/dev/null

  install_baseline_packages
  install_containerd
  install_runc
  install_cni_plugins
  install_kube_tools
  install_crictl
  configure_crictl

  log "Common prep complete on $(hostname)."
}

install_containerd() {
  if command -v containerd >/dev/null && containerd --version | grep -q "$CONTAINERD_VERSION"; then
    log "containerd $CONTAINERD_VERSION already installed; skipping."
    return
  fi
  log "Installing containerd ${CONTAINERD_VERSION}…"
  local tmp
  tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
  tar Cxzf /usr/local "containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"

  curl -fsSLo /usr/local/lib/systemd/system/containerd.service \
       --create-dirs \
       https://raw.githubusercontent.com/containerd/containerd/main/containerd.service

  mkdir -p /etc/containerd
  containerd config default | tee /etc/containerd/config.toml >/dev/null
  # Use the systemd cgroup driver (matches kubelet's default).
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  systemctl daemon-reload
  systemctl enable --now containerd
  popd >/dev/null
  rm -rf "$tmp"
  systemctl is-active --quiet containerd || die "containerd failed to start"
  log "containerd up."
}

install_runc() {
  if command -v runc >/dev/null && runc --version | grep -q "$RUNC_VERSION"; then
    log "runc $RUNC_VERSION already installed; skipping."
    return
  fi
  log "Installing runc ${RUNC_VERSION}…"
  curl -fsSLo /tmp/runc.${ARCH} \
       "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${ARCH}"
  install -m 755 /tmp/runc.${ARCH} /usr/local/sbin/runc
  rm -f /tmp/runc.${ARCH}
}

install_cni_plugins() {
  if [[ -x /opt/cni/bin/bridge ]] && /opt/cni/bin/bridge 2>&1 | grep -q "$CNI_PLUGINS_VERSION"; then
    log "CNI plugins $CNI_PLUGINS_VERSION already installed; skipping."
    return
  fi
  log "Installing CNI plugins ${CNI_PLUGINS_VERSION}…"
  mkdir -p /opt/cni/bin
  curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-v${CNI_PLUGINS_VERSION}.tgz" \
       | tar -C /opt/cni/bin -xz
}

install_baseline_packages() {
  log "Installing baseline packages (tar, socat, conntrack, …)…"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y apt-transport-https ca-certificates curl gpg socat \
                       conntrack ebtables ethtool iproute2 iptables tar gzip
  else
    # RHEL / Amazon Linux / Rocky / Alma / Fedora.
    # NOTE: we deliberately do NOT install `curl` or `gnupg2` here. Amazon
    # Linux 2023 (and recent Fedora/RHEL) ship `curl-minimal` / `gnupg2-minimal`
    # which satisfy our needs, and asking for the full packages triggers a
    # file-conflict and dnf refuses without --allowerasing.
    local pm
    pm="$(command -v dnf || command -v yum)"
    "$pm" install -y ca-certificates socat ethtool iproute iptables tar gzip \
                     conntrack-tools || \
      "$pm" install -y ca-certificates socat ethtool iproute iptables tar gzip \
                       conntrack    # AL2 / some RHEL variants use plain "conntrack"
  fi

  # Make sure the binaries we actually rely on are present.
  for bin in curl tar gzip; do
    command -v "$bin" >/dev/null || die "$bin not on PATH after baseline install"
  done
}

install_kube_tools() {
  if command -v kubeadm >/dev/null && kubeadm version -o short 2>/dev/null | grep -q "${K8S_PKG_VERSION%-*}"; then
    log "kubeadm ${K8S_PKG_VERSION} already installed; skipping."
    return
  fi
  log "Installing kubeadm/kubelet/kubectl ${K8S_PKG_VERSION}…"

  if [[ "$OS_FAMILY" == "debian" ]]; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
         | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
         > /etc/apt/sources.list.d/kubernetes.list

    apt-get update -y
    apt-get install -y --allow-downgrades --allow-change-held-packages \
          "kubelet=${K8S_PKG_VERSION}" \
          "kubeadm=${K8S_PKG_VERSION}" \
          "kubectl=${K8S_PKG_VERSION}"
    apt-mark hold kubelet kubeadm kubectl
  else
    # RPM repo. Note the rpm package versions use a "-150500.1.1" style suffix;
    # convert "1.34.8-1.1" -> "1.34.8" for the rpm name.
    local rpm_ver="${K8S_PKG_VERSION%-*}"
    cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    local pm
    pm="$(command -v dnf || command -v yum)"
    # SELinux must be permissive for kubelet (kubeadm docs).
    if command -v setenforce >/dev/null 2>&1; then
      setenforce 0 || true
      [[ -f /etc/selinux/config ]] && \
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    fi
    "$pm" install -y --disableexcludes=kubernetes \
          "kubelet-${rpm_ver}" "kubeadm-${rpm_ver}" "kubectl-${rpm_ver}"
    # Pin packages so a regular `dnf update` doesn't bump them unexpectedly.
    if command -v dnf >/dev/null && dnf versionlock --help >/dev/null 2>&1; then
      dnf versionlock add kubelet kubeadm kubectl >/dev/null 2>&1 || true
    fi
  fi
  systemctl enable --now kubelet
}

# Persistently rename this node. On AWS / cloud-init systems the default
# hostname (e.g. ip-172-31-12-51) gets reset at every boot, so we also have
# to disable cloud-init's hostname management. Safe to call multiple times.
set_hostname() {
  local new="$1"
  [[ -n "$new" ]] || die "set_hostname called with empty name"

  # RFC 1123 sanity check: lowercase alphanumeric + dashes, no leading/trailing dash.
  if ! [[ "$new" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    die "node name '$new' is invalid (must be lowercase, alphanumeric + dashes, RFC 1123)"
  fi

  local current; current="$(hostname -s)"
  if [[ "$current" == "$new" ]]; then
    log "Hostname already '$new'; nothing to change."
    return
  fi

  log "Renaming this node from '$current' to '$new'…"
  hostnamectl set-hostname "$new"
  echo "$new" > /etc/hostname

  # Make `$new` resolve to 127.0.0.1 (kubelet checks this).
  if ! grep -qE "^[0-9.]+\s+$new(\s|$)" /etc/hosts; then
    echo "127.0.0.1   $new" >> /etc/hosts
  fi

  # On Amazon Linux / Ubuntu cloud images, cloud-init will rewrite the hostname
  # on every reboot unless we tell it not to. Two settings matter:
  #   preserve_hostname: true   → don't touch hostname on subsequent boots
  #   manage_etc_hosts: false   → don't rewrite /etc/hosts either
  if [[ -d /etc/cloud ]]; then
    log "Disabling cloud-init hostname management so the rename survives reboot…"
    mkdir -p /etc/cloud/cloud.cfg.d
    cat >/etc/cloud/cloud.cfg.d/99-k8s-hostname.cfg <<EOF
# Written by k8s-install.sh — keep the Kubernetes node name across reboots.
preserve_hostname: true
manage_etc_hosts: false
EOF
  fi
}

configure_crictl() {
  # package was removed, /usr/local/bin not on PATH for root, etc.) install it
  # now before we try to use it.
  if ! command -v crictl >/dev/null 2>&1; then
    warn "crictl not found on PATH — installing as a fail-safe."
    install_crictl
  fi

  log "Pointing crictl at containerd…"
  cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF

  # Sanity check — surfaces socket/permissions issues early instead of at
  # `kubeadm init` preflight time.
  if ! crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock \
              info >/dev/null 2>&1; then
    warn "crictl could not talk to containerd yet. Service may still be starting."
  else
    log "crictl ↔ containerd link verified."
  fi
}

install_crictl() {
  if command -v crictl >/dev/null 2>&1 \
     && crictl --version 2>/dev/null | grep -q "${CRICTL_VERSION}"; then
    log "crictl ${CRICTL_VERSION} already installed; skipping."
    return
  fi
  log "Installing crictl v${CRICTL_VERSION}…"
  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fsSLO "https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/crictl-v${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
  tar -xzf "crictl-v${CRICTL_VERSION}-linux-${ARCH}.tar.gz" -C /usr/local/bin
  chmod +x /usr/local/bin/crictl
  popd >/dev/null
  rm -rf "$tmp"
  command -v crictl >/dev/null || die "crictl install failed — binary not on PATH"
}

# -----------------------------------------------------------------------------
# 2. Initialize the control plane
# -----------------------------------------------------------------------------
init_control_plane() {
  require_root
  local advertise_addr=""
  local node_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apiserver-address) advertise_addr="$2"; shift 2 ;;
      --node-name)         node_name="$2";      shift 2 ;;
      *) shift ;;
    esac
  done

  # Auto-detect primary IP if not supplied.
  if [[ -z "$advertise_addr" ]]; then
    advertise_addr="$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')"
    log "Auto-detected API-server advertise address: $advertise_addr"
  fi

  # If user passed --node-name, rename the host BEFORE kubeadm runs.
  if [[ -n "$node_name" ]]; then
    set_hostname "$node_name"
  else
    node_name="$(hostname -s)"
  fi

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    warn "Control plane appears already initialized (/etc/kubernetes/admin.conf exists). Skipping kubeadm init."
  else
    log "Running kubeadm init (node name: ${node_name})…"
    kubeadm init \
      --pod-network-cidr="$POD_CIDR" \
      --apiserver-advertise-address="$advertise_addr" \
      --node-name="$node_name" \
      --upload-certs
  fi

  log "Setting up kubeconfig for current sudo user…"
  local home_dir target_user
  target_user="${SUDO_USER:-$USER}"
  home_dir="$(getent passwd "$target_user" | cut -d: -f6)"
  mkdir -p "${home_dir}/.kube"
  cp -f /etc/kubernetes/admin.conf "${home_dir}/.kube/config"
  chown -R "${target_user}:${target_user}" "${home_dir}/.kube"
  # Also for root, since this script runs under sudo.
  mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config

  install_calico

  log "Generating fresh join command…"
  local join_cmd
  join_cmd="$(kubeadm token create --print-join-command)"
  echo
  echo "================================================================================"
  echo "  CLUSTER UP. Run the following on each worker node to join it:"
  echo
  echo "    sudo ./k8s-install.sh join --node-name worker-N \\"
  echo "         \"${join_cmd}\""
  echo
  echo "  Replace N with a UNIQUE number per worker (worker-1, worker-2, …)."
  echo "  Duplicate names will collide — each worker MUST have a different name."
  echo
  echo "  (You can also omit --node-name to keep the default ip-X-X-X-X hostname.)"
  echo
  echo "  After all workers have joined, run this on the CONTROL PLANE to tag them:"
  echo
  echo "    sudo ./k8s-install.sh label-workers"
  echo "================================================================================"
}

install_calico() {
  log "Installing Calico ${CALICO_VERSION} via the Tigera operator…"
  export KUBECONFIG=/etc/kubernetes/admin.conf
  # Wait for the API to be reachable.
  until kubectl get --raw=/healthz >/dev/null 2>&1; do sleep 2; done

  kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

  # The Tigera operator registers Calico's CRDs (Installation, APIServer,
  # Goldmane, Whisker) only AFTER its Deployment is healthy. Applying
  # custom-resources.yaml before that races and fails with
  # `no matches for kind "Installation" in version "operator.tigera.io/v1"`.
  log "Waiting for tigera-operator Deployment to become ready…"
  kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=5m

  log "Waiting for Calico CRDs to be registered by the operator…"
  local deadline=$((SECONDS + 180))
  until kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      die "Calico CRDs were not registered within 3 minutes — check 'kubectl -n tigera-operator logs deploy/tigera-operator'"
    fi
    sleep 3
  done
  # Tiny grace period for the other CRDs (APIServer/Goldmane/Whisker) to land.
  kubectl wait --for=condition=Established --timeout=60s \
    crd/installations.operator.tigera.io \
    crd/apiservers.operator.tigera.io >/dev/null 2>&1 || true

  # Custom resources with our pod CIDR substituted in.
  local tmp; tmp="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" -o "$tmp"
  sed -i "s|cidr:.*|cidr: ${POD_CIDR}|" "$tmp"
  kubectl apply -f "$tmp"
  rm -f "$tmp"

  log "Waiting for Calico to roll out (this can take a few minutes)…"
  kubectl wait --for=condition=Ready nodes --all --timeout=10m \
    || warn "nodes not Ready yet — check 'kubectl get pods -A' and 'kubectl describe -n calico-system installation default'"
}

# -----------------------------------------------------------------------------
# 3. Join a worker
# -----------------------------------------------------------------------------
join_worker() {
  require_root

  # Parse args: optional --node-name <name>, then the kubeadm join command.
  local node_name=""
  local join_cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node-name) node_name="$2"; shift 2 ;;
      *) join_cmd="$1"; shift ;;
    esac
  done

  [[ -n "$join_cmd" ]] || die "usage: $0 join [--node-name <name>] \"<kubeadm join … command>\""

  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    warn "Node already joined (/etc/kubernetes/kubelet.conf exists). Skipping."
    return
  fi

  # If user passed --node-name, rename the host BEFORE kubeadm runs. Otherwise
  # use the existing short hostname (e.g. ip-172-31-30-221).
  if [[ -n "$node_name" ]]; then
    set_hostname "$node_name"
  else
    node_name="$(hostname -s)"
  fi

  log "Joining cluster as node '${node_name}'…"
  # shellcheck disable=SC2086
  eval $join_cmd --node-name="${node_name}"

  log "Joined. On the CONTROL PLANE, run:"
  log "  sudo ./k8s-install.sh label-workers"
  log "…to tag this node with ROLES=worker."
}

# -----------------------------------------------------------------------------
# 4. Label any unlabeled worker nodes (run on control plane after join)
# -----------------------------------------------------------------------------
label_workers() {
  require_root
  if [[ ! -f /etc/kubernetes/admin.conf ]]; then
    die "admin.conf not found — run this on the CONTROL PLANE node, after init."
  fi
  export KUBECONFIG=/etc/kubernetes/admin.conf

  log "Looking for nodes without a role label…"
  # A "worker" is any node that is NOT a control plane. Find those whose
  # ROLES column would be <none> and label them.
  local nodes
  nodes="$(kubectl get nodes \
            -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/worker' \
            -o jsonpath='{.items[*].metadata.name}')"

  if [[ -z "$nodes" ]]; then
    log "No unlabeled worker nodes found. Nothing to do."
    return
  fi

  for n in $nodes; do
    log "Labelling ${n} as worker…"
    kubectl label node "$n" node-role.kubernetes.io/worker= --overwrite >/dev/null
  done
  log "Done. Current nodes:"
  kubectl get nodes
}

# -----------------------------------------------------------------------------
# 5. Single-node lab cluster (control plane + workloads on same machine)
# -----------------------------------------------------------------------------
all_in_one() {
  prep_node
  init_control_plane "$@"
  log "Removing control-plane taint so this single node can run user pods…"
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
}

# -----------------------------------------------------------------------------
usage() {
  sed -n '2,47p' "$0"
  exit 1
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    prep)           prep_node ;;
    init)           prep_node; init_control_plane "$@" ;;
    join)           prep_node; join_worker "$@" ;;
    label-workers)  label_workers ;;
    all-in-one)     all_in_one "$@" ;;
    -h|--help|"")   usage ;;
    *) die "unknown command: $cmd (see --help)" ;;
  esac
}

main "$@"

# Here's the mental model — what the script actually does, in order, when you run `sudo ./k8s-install.sh init` on a control plane node. The `join` flow is the same up to step 11.

# ## The prep phase (steps 1–11)

# These run on **every** node (master and workers), because every node needs to be able to run pods.

# 1. **Disable swap** — Linux page-swapping to disk breaks kubelet's memory accounting, so we turn it off and comment it out in `/etc/fstab` so it stays off across reboots.

# 2. **Load kernel modules** — `overlay` (the storage driver containerd uses to stack image layers efficiently) and `br_netfilter` (lets iptables see traffic crossing Linux network bridges, which is how pods talk to each other on a node).

# 3. **Set sysctl params** — three networking knobs: forward IPv4 packets (otherwise pods on different nodes can't reach each other), and let iptables filter bridged traffic for both IPv4 and IPv6.

# 4. **Install baseline OS packages** — small utilities Kubernetes needs at runtime: `socat` (port forwarding for `kubectl port-forward`), `conntrack` (connection tracking for kube-proxy's iptables rules), `ethtool`, `iproute`, `iptables`, `tar`, `gzip`.

# 5. **Install containerd** — the **container runtime**. This is what actually starts and stops containers on the node. It pulls images, manages container lifecycles, sets up cgroups. kubelet talks to it via the CRI (Container Runtime Interface).

# 6. **Install runc** — the **low-level runtime** containerd uses underneath. runc is what actually invokes the Linux kernel syscalls (`clone`, `unshare`, `pivot_root`) that create the namespaces and cgroups for a running container. containerd is the manager; runc is the worker.

# 7. **Install CNI plugins** — binaries dropped into `/opt/cni/bin/`. CNI = Container Network Interface. These are small standardised programs (`bridge`, `host-local`, `loopback`, `portmap`, etc.) that kubelet invokes whenever a pod is created or destroyed, to set up its network interfaces. Calico will use some of these later.

# 8. **Install kubeadm / kubelet / kubectl** — the three Kubernetes binaries:
#    - **kubelet** = the agent that runs on every node; it talks to the API server, receives pod specs, and tells containerd what to run.
#    - **kubeadm** = the bootstrapper that initializes/joins clusters (you run it once per node).
#    - **kubectl** = the human/admin CLI (technically only needed on the master, but installed everywhere for convenience).

# 9. **Install crictl** — debugging CLI for talking to containerd via the CRI. Lets you do things like `crictl ps` (containers running on this node), `crictl logs`, `crictl pull`. Not used at runtime, but invaluable when something breaks.

# 10. **Configure crictl** — write `/etc/crictl.yaml` pointing it at containerd's Unix socket, then run a sanity check (`crictl info`) to confirm the link works. Surfaces problems here instead of at `kubeadm init`'s preflight step.

# 11. **kubelet enabled to start at boot** — but doesn't actually start fully yet; it'll keep crashing in a loop until step 12 gives it something to do. (This is normal and expected.)

# ## The init phase (steps 12–17) — control plane only

# These run **only on the master** when you use `init`.

# 12. **Auto-detect the API server IP** — script grabs the node's primary IPv4 address (the one used to reach the internet), so you don't have to hardcode it.

# 13. **`kubeadm init`** — the big one. kubeadm pulls 5 control-plane container images (kube-apiserver, kube-controller-manager, kube-scheduler, etcd, pause), generates a full PKI tree of certificates (CA, API server cert, etcd certs, service account signing key…), writes static pod manifests to `/etc/kubernetes/manifests/`, then kubelet sees them and starts the control plane components. Also creates the `kube-system` namespace, sets up RBAC, generates a bootstrap token for workers, and deploys CoreDNS + kube-proxy.

# 14. **Set up your kubeconfig** — copies `/etc/kubernetes/admin.conf` to `~/.kube/config` for your sudo user so you can run `kubectl` without being root.

# 15. **Install the Tigera operator** — applies the Calico operator manifest (`tigera-operator.yaml`). This deploys *one* Deployment in the `tigera-operator` namespace, whose job is to manage Calico. It doesn't install Calico itself yet — it just sits there waiting for instructions.

# 16. **Wait for Calico CRDs to be registered** — once the operator pod is running, it publishes Calico's custom resource definitions (`Installation`, `APIServer`, `Goldmane`, `Whisker`) to the API server. The script polls until `installations.operator.tigera.io` exists, because applying the next step before that would race.

# 17. **Apply Calico's custom resources** — creates an `Installation` resource with your pod CIDR (192.168.0.0/16). The operator sees it and creates the `calico-system` namespace, then deploys: `calico-node` (a DaemonSet — one pod per node, responsible for pod networking and BGP/VXLAN), `calico-kube-controllers` (housekeeping), `calico-typha` (a caching layer for scale), and a few extras. When `calico-node` lands on the master, the master flips from `NotReady` → `Ready`.

# 18. **Print the join command** — generates a fresh token via `kubeadm token create --print-join-command` and prints it. Save this — workers need it.

# ## The join phase (steps 19–22) — workers only

# When you run `join` on a worker, steps 1–11 happen again (each worker needs the runtime stack), then:

# 19. **`kubeadm join`** — connects to the API server using the token from step 18, requests a kubelet certificate (signed by the cluster CA), and writes `/etc/kubernetes/kubelet.conf` so kubelet knows who it is and how to reach the API.

# 20. **kubelet starts reporting** — registers the node with the API server. The scheduler now sees a new node.

# 21. **Calico spawns automatically** — the `calico-node` DaemonSet sees the new node, schedules a `calico-node` pod on it. That pod sets up pod networking on the worker (interfaces, routes, VXLAN tunnels). Node flips to `Ready`.

# 22. **Self-label as `worker`** — uses the kubelet's own credentials to add the `node-role.kubernetes.io/worker=` label, so `kubectl get nodes` shows ROLES=worker instead of `<none>`.

# ## The vertical stack on a finished node

# This is the picture you should carry in your head:

# ```
#                   ┌─────────────────────────────────────┐
#                   │  Kubernetes API (on the master)     │
#                   └────────────────▲────────────────────┘
#                                    │  HTTPS (port 6443)
#                                    │
#    ┌───────────────────────────────┴──────────────────────────────┐
#    │                       kubelet (systemd)                       │
#    │   - watches API for pods assigned to this node                │
#    │   - tells containerd to start/stop them                       │
#    │   - invokes CNI plugins to wire up pod networking             │
#    └─────┬─────────────────────────────────────┬───────────────────┘
#          │ CRI (Unix socket)                   │ exec
#          ▼                                     ▼
#    ┌─────────────┐                       ┌───────────────┐
#    │ containerd  │ ──────── exec ──────▶ │     runc      │
#    │ (manager)   │                       │ (spawns the   │
#    └──────┬──────┘                       │  container)   │
#           │                              └───────────────┘
#           ▼
#     pulls images, manages cgroups, mounts overlay filesystems

#    ┌─────────────────────────────────────────────────────────┐
#    │   /opt/cni/bin/  ←  CNI plugins, invoked per pod        │
#    │   Calico's calico-node DaemonSet uses these to wire     │
#    │   pod IPs, routes, and VXLAN tunnels between nodes.     │
#    └─────────────────────────────────────────────────────────┘
# ```

# That's the whole thing. Every component above has a clear job and they talk through well-defined interfaces (CRI, CNI, the Kubernetes API). Once you internalize this layered picture, you can read any K8s error message and immediately know *which layer* is failing — which is the actual point of the whole exercise.

# Congrats on the cluster! 🎉