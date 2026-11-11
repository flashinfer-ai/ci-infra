#!/bin/bash
# Pre-pull the FlashInfer CI images into ubuntu's rootless Docker data root
# (~ubuntu/.local/share/docker), the store templates/user-data.sh's rootless
# dockerd uses at boot. Runs over SSH as ubuntu inside Packer.
#
# Docker is installed the same way user-data.sh installs it, so at boot its apt
# steps find the packages present and the rootless daemon opens the baked store
# with the same storage driver. The rootless service itself is uninstalled again
# at the end (its data stays), leaving user-data.sh to set it up as it does on a
# stock AMI.
set -euo pipefail

: "${CI_IMAGES:?CI_IMAGES must list the images to pull}"

sudo cloud-init status --wait >/dev/null || true

# Same packages as templates/user-data.sh.
echo 'DPkg::Lock::Timeout "300";' | sudo tee /etc/apt/apt.conf.d/99-lock-timeout >/dev/null
sudo apt-get -q update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
    build-essential ca-certificates curl git iptables jq systemd-container \
    uidmap unzip wget

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
# shellcheck source=/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get -q update
sudo DEBIAN_FRONTEND=noninteractive apt-get -q -y install \
    docker-ce docker-ce-cli containerd.io docker-ce-rootless-extras \
    docker-buildx-plugin docker-compose-plugin
sudo systemctl disable --now docker.socket docker.service

# Rootless Docker for ubuntu, as user-data.sh sets it up.
user_id=$(id -ru)
sudo loginctl enable-linger "$(id -un)"
export XDG_RUNTIME_DIR="/run/user/${user_id}"
for _ in $(seq 30); do
    [[ -d ${XDG_RUNTIME_DIR} ]] && break
    sleep 1
done
dockerd-rootless-setuptool.sh install
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
docker info --format 'storage driver: {{.Driver}}, root: {{.DockerRootDir}}'

pull_with_retry() {
    local image=$1 attempt
    for attempt in 1 2 3 4; do
        if docker pull --quiet "${image}"; then
            return 0
        fi
        echo "pull of ${image} failed (attempt ${attempt}/4)" >&2
        sleep $((attempt * 30))
    done
    return 1
}

# One image at a time: extraction is CPU- and disk-bound, and parallel pulls of
# images that share base layers would only wait on each other.
for image in ${CI_IMAGES}; do
    start=$(date +%s)
    pull_with_retry "${image}"
    echo "pulled ${image} in $(( $(date +%s) - start ))s"
done

docker image ls
# Record what was baked, for debugging a runner (cat /etc/flashinfer-ci-images).
for image in ${CI_IMAGES}; do
    docker image inspect --format '{{index .RepoTags 0}} {{.Id}} {{json .RepoDigests}}' "${image}"
done | sudo tee /etc/flashinfer-ci-images >/dev/null
df -h /

# Stop and unregister the rootless service; uninstall keeps the data root.
systemctl --user stop docker.service
dockerd-rootless-setuptool.sh uninstall
sudo loginctl disable-linger "$(id -un)"

sudo apt-get clean
sudo cloud-init clean --logs
