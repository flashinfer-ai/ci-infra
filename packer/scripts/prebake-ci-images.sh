#!/bin/bash
# Pre-pull the FlashInfer CI images into the Docker store the runner's
# user-data starts at boot. Runs over SSH as ubuntu inside Packer
# (packer/runner.pkr.hcl).
#
# RUNNER_FLAVOR=cpu: stock Ubuntu. Docker is installed the way
#   templates/user-data.sh installs it, and the images go into ubuntu's rootless
#   data root (~ubuntu/.local/share/docker). The rootless service is uninstalled
#   again at the end (its data stays), so user-data.sh sets it up as it does on
#   a stock AMI, finding the packages present and the images in place.
# RUNNER_FLAVOR=gpu: the Deep Learning AMI, whose rootful Docker keeps its data
#   in /var/lib/docker on the root volume. templates/user-data-gpu.sh rewrites
#   daemon.json (runtime, log settings) and restarts Docker, neither of which
#   touches the image store.
set -euo pipefail

: "${CI_IMAGES:?CI_IMAGES must list the images to pull}"
: "${RUNNER_FLAVOR:?RUNNER_FLAVOR must be cpu or gpu}"

sudo cloud-init status --wait >/dev/null || true

setup_rootless_docker() {
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
    local user_id
    user_id=$(id -ru)
    sudo loginctl enable-linger "$(id -un)"
    export XDG_RUNTIME_DIR="/run/user/${user_id}"
    for _ in $(seq 30); do
        [[ -d ${XDG_RUNTIME_DIR} ]] && break
        sleep 1
    done
    dockerd-rootless-setuptool.sh install
    export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
    DOCKER=(docker)
}

teardown_rootless_docker() {
    # Stop and unregister the rootless service; uninstall keeps the data root.
    systemctl --user stop docker.service
    dockerd-rootless-setuptool.sh uninstall
    sudo loginctl disable-linger "$(id -un)"
}

setup_rootful_docker() {
    sudo systemctl start docker
    DOCKER=(sudo docker)
}

teardown_rootful_docker() {
    sudo systemctl stop docker.socket docker.service
}

case ${RUNNER_FLAVOR} in
    cpu) setup_rootless_docker ;;
    gpu) setup_rootful_docker ;;
    *) echo "unknown RUNNER_FLAVOR ${RUNNER_FLAVOR}" >&2; exit 1 ;;
esac
"${DOCKER[@]}" info --format 'storage driver: {{.Driver}}, root: {{.DockerRootDir}}'

pull_with_retry() {
    local image=$1 attempt
    for attempt in 1 2 3 4; do
        if "${DOCKER[@]}" pull --quiet "${image}"; then
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

"${DOCKER[@]}" image ls
# Record what was baked, for debugging a runner (cat /etc/flashinfer-ci-images).
for image in ${CI_IMAGES}; do
    "${DOCKER[@]}" image inspect --format '{{index .RepoTags 0}} {{.Id}} {{json .RepoDigests}}' "${image}"
done | sudo tee /etc/flashinfer-ci-images >/dev/null
df -h /

case ${RUNNER_FLAVOR} in
    cpu) teardown_rootless_docker ;;
    gpu) teardown_rootful_docker ;;
esac

sudo apt-get clean
sudo cloud-init clean --logs
