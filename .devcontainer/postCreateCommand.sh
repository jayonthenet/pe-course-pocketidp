#!/usr/bin/env bash
sudo apt-get install -y curl unzip wget net-tools jq

# Check if dockerd is running
if ! pgrep -x "dockerd" > /dev/null
then
  echo "Docker daemon is not running. Starting dockerd in the background..."
  sudo dockerd > /dev/null 2>&1 &
else
  echo "Docker daemon is already running."
fi

# For Terraform 1.5.7
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    ARCH="arm64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi
VERSION="1.5.7"
wget "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_${ARCH}.zip"
unzip terraform_${VERSION}_linux_${ARCH}.zip
sudo mv terraform /usr/local/bin/
rm terraform_${VERSION}_linux_${ARCH}.zip

# For YQ
VERSION="v4.35.1" # Replace with the desired version
wget "https://github.com/mikefarah/yq/releases/download/${VERSION}/yq_linux_${ARCH}"
sudo mv yq_linux_${ARCH} /usr/local/bin/yq

# For score-k8s AMD64 / x86_64
[ $(uname -m) = x86_64 ] && curl -sLO "https://github.com/score-spec/score-k8s/releases/download/0.1.18/score-k8s_0.1.18_linux_amd64.tar.gz"
# For score-k8s ARM64
[ $(uname -m) = aarch64 ] && curl -sLO "https://github.com/score-spec/score-k8s/releases/download/0.1.18/score-k8s_0.1.18_linux_arm64.tar.gz"
tar xvzf score-k8s*.tar.gz
rm score-k8s*.tar.gz README.md LICENSE
sudo mv ./score-k8s /usr/local/bin/score-k8s
sudo chown root: /usr/local/bin/score-k8s

# For Kubectl AMD64 / x86_64
[ $(uname -m) = x86_64 ] && curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
# For Kubectl ARM64
[ $(uname -m) = aarch64 ] && curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/arm64/kubectl"
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl

# For Kind AMD64 / x86_64
[ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.26.0/kind-linux-amd64
# For ARM64
[ $(uname -m) = aarch64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.26.0/kind-linux-arm64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# setup autocomplete for kubectl
sudo apt-get update -y && sudo apt-get install bash-completion -y
mkdir $HOME/.kube
echo "source <(kubectl completion bash)" >> $HOME/.bashrc
echo "complete -F __start_kubectl k" >> $HOME/.bashrc
docker network create -d=bridge -o com.docker.network.bridge.enable_ip_masquerade=true -o com.docker.network.driver.mtu=1500 --subnet fc00:f853:ccd:e793::/64 kind

export BASE_DIR=/home/vscode
mkdir -p $BASE_DIR/state/kube

# 1. Create registry container unless it already exists
reg_name='kind-registry'
reg_port='5001'
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" registry:2
fi

# 2. Create Kind cluster
if [ ! -f $BASE_DIR/state/kube/config.yaml ]; then
  kind create cluster -n 5min-idp --kubeconfig $BASE_DIR/state/kube/config.yaml --config ./setup/kind/cluster.yaml
fi

# connect current container to the kind network
container_name="5min-idp"
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${container_name}")" = 'null' ]; then
  docker network connect "kind" "${container_name}"
fi

# used by humanitec-agent / inside docker to reach the cluster
kubeconfig_docker=$BASE_DIR/state/kube/config-internal.yaml
kind export kubeconfig --internal  -n 5min-idp --kubeconfig "$kubeconfig_docker"

# 3. Add the registry config to the nodes
#
# This is necessary because localhost resolves to loopback addresses that are
# network-namespace local.
# In other words: localhost in the container is not localhost on the host.
#
# We want a consistent name that works from both ends, so we tell containerd to
# alias localhost:${reg_port} to the registry container when pulling images
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${reg_port}"
for node in $(kind get nodes -n 5min-idp); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${reg_name}:5000"]
EOF
done

# 4. Connect the registry to the cluster network if not already connected
# This allows kind to bootstrap the network but ensures they're on the same network
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi

# 5. Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
  host: "localhost:${reg_port}"
  help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo ""
echo ">>>> Everything prepared, ready to deploy application."

## Update /etc/hosts with the kind cluster name
echo "127.0.0.1 5min-idp-control-plane" | sudo tee -a /etc/hosts

## Prep env
# Get the gateway API in if we want to work with score-k8s
#kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
# ATTENTION WITH THIS ONE - we need this at least for Git to be able to interact with the self-signed cert
echo "git config --global user.name \"giteaAdmin\"" >> $HOME/.bashrc
echo "git config --global credential.helper store" >> $HOME/.bashrc
# Set some nice aliases
echo "alias k='kubectl'" >> $HOME/.bashrc
echo "alias kg='kubectl get'" >> $HOME/.bashrc
echo "alias h='humctl'" >> $HOME/.bashrc
echo "alias sk='score-k8s'" >> $HOME/.bashrc
