#!/usr/bin/env bash

set -euo pipefail

# Kubernetes Master Installation Script v1.30
# Must be run as root (e.g., via sudo)

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (e.g., sudo)." >&2
  exit 1
fi

# Determine the non-root user (for kubeconfig setup)
TARGET_USER=${SUDO_USER:-root}
TARGET_HOME=$(eval echo "~${TARGET_USER}")

# Update & prerequisites
echo "[INFO] Updating system and installing prerequisites..."
apt update && apt upgrade -y
apt install -y apt-transport-https curl

# Install containerd
echo "[INFO] Installing and configuring containerd..."
apt install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd

# Add Kubernetes apt repository (v1.30)
echo "[INFO] Adding Kubernetes APT repository..."
install -m0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /
EOF
apt update

# Install kubelet, kubeadm, kubectl
echo "[INFO] Installing kubelet, kubeadm, kubectl..."
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Disable swap
echo "[INFO] Disabling swap..."
swapoff -a
sed -i '/ swap / s|^|#|' /etc/fstab

# Load kernel modules and sysctl params
echo "[INFO] Loading kernel modules and applying sysctl settings..."
modprobe overlay
modprobe br_netfilter
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Initialize Kubernetes master
echo "[INFO] Initializing Kubernetes master node..."
kubeadm init --pod-network-cidr=10.244.0.0/16

# Setup kubeconfig for target user
echo "[INFO] Configuring kubectl for user '${TARGET_USER}'..."
mkdir -p "${TARGET_HOME}/.kube"
cp -i /etc/kubernetes/admin.conf "${TARGET_HOME}/.kube/config"
chown ${TARGET_USER}:${TARGET_USER} "${TARGET_HOME}/.kube/config"

# Deploy Calico
echo "[INFO] Deploying Calico..."
runuser -l ${TARGET_USER} -c "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/calico.yaml"

# Final info
echo "[SUCCESS] Kubernetes master setup complete."
echo "Run as '${TARGET_USER}': kubectl get nodes to verify cluster status."
