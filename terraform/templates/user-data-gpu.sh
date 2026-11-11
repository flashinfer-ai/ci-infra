#!/bin/bash
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# AWS suggest to create a log for debug purpose based on https://aws.amazon.com/premiumsupport/knowledge-center/ec2-linux-log-user-data/
set +x

%{ if enable_debug_logging }
set -x
%{ endif }

${pre_install}

# Automatic upgrades restart dbus, which kills dockerd's in-flight request to
# systemd for a container's cgroup scope and fails the job.
systemctl stop --no-block apt-daily.timer apt-daily-upgrade.timer \
    unattended-upgrades.service 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer \
    apt-daily.service apt-daily-upgrade.service \
    unattended-upgrades.service 2>/dev/null || true

# Wait out an upgrade that is already holding the dpkg lock.
echo 'DPkg::Lock::Timeout "300";' > /etc/apt/apt.conf.d/99-lock-timeout

# Deep Learning AMI already has Docker and NVIDIA drivers installed
# Just ensure dependencies are up to date
apt-get -q update
DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
    build-essential \
    ca-certificates \
    curl \
    git \
    jq \
    unzip \
    wget

# Install AWS CLI v2 if not present
if ! command -v aws &> /dev/null; then
    curl -fsSL -o "awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
fi

user_name=ubuntu
user_id=$(id -ru $user_name)

# Install and configure cloudwatch logging agent
curl -fsSL -o "/tmp/amazon-cloudwatch-agent.deb" "https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/$(dpkg --print-architecture)/latest/amazon-cloudwatch-agent.deb"
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb
rm -f /tmp/amazon-cloudwatch-agent.deb
amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "ssm:${ssm_key_cloudwatch_agent_config}"

# Ensure Docker service is running (Deep Learning AMI has Docker pre-installed)
systemctl enable docker
systemctl start docker

# Add ubuntu user to docker group
usermod -aG docker $user_name

# Move Docker and containerd storage to the instance-store NVMe that the Deep
# Learning AMI mounts at /opt/dlami/nvme (412 GB on g5.2xlarge, 206 GB on
# g4dn.2xlarge), as user-data-multi-runner.sh does for the H100/B200 runners.
# On the gp3 root (125 MB/s, 3000 IOPS) the 11.6 GB cu129 CI image took
# 4.5-7.9 min to pull, 50-80% of a targeted A10G job. The instance store is
# included in the instance price and its contents only need to live as long as
# the runner. Instances without instance store keep using the root volume, and
# so does an AMI with the CI images already baked into /var/lib/docker
# (/etc/flashinfer-ci-images, packer/scripts/prebake-ci-images.sh): copying
# them off a freshly restored root volume would be slower than using them there.
if mountpoint -q /opt/dlami/nvme && [ ! -e /etc/flashinfer-ci-images ]; then
    echo "Moving Docker storage to NVMe..."
    systemctl stop docker docker.socket containerd 2>/dev/null || true
    mkdir -p /opt/dlami/nvme/docker /opt/dlami/nvme/containerd
    if [ -d /var/lib/docker ] && [ ! -L /var/lib/docker ]; then
        rsync -a /var/lib/docker/ /opt/dlami/nvme/docker/ 2>/dev/null || true
        rm -rf /var/lib/docker
    fi
    if [ -d /var/lib/containerd ] && [ ! -L /var/lib/containerd ]; then
        rsync -a /var/lib/containerd/ /opt/dlami/nvme/containerd/ 2>/dev/null || true
        rm -rf /var/lib/containerd
    fi
    ln -sfn /opt/dlami/nvme/docker /var/lib/docker
    ln -sfn /opt/dlami/nvme/containerd /var/lib/containerd
    systemctl start containerd docker
else
    echo "No instance store or pre-baked images; Docker stays on the root volume"
fi

# Configure NVIDIA Container Toolkit for Docker
# First, run nvidia-ctk to add the nvidia runtime
nvidia-ctk runtime configure --runtime=docker

# Configure Docker daemon with nvidia runtime and stability settings
# - default-runtime: nvidia (for --gpus all support)
# - max-concurrent-downloads: limit parallel layer downloads to reduce memory pressure
# - max-concurrent-uploads: limit parallel layer uploads
# Note: live-restore is NOT enabled as it can cause gRPC instability with nvidia-container-runtime
cat > /etc/docker/daemon.json <<'DOCKER_CONFIG'
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    },
    "max-concurrent-downloads": 3,
    "max-concurrent-uploads": 3,
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    }
}
DOCKER_CONFIG

echo "=== Docker daemon.json ==="
cat /etc/docker/daemon.json

# Restart Docker to apply changes
systemctl restart docker

# Verify Docker configuration (no external image pull needed)
echo "=== Docker GPU Runtime Config ==="
docker info | grep -iE "runtime|default" || true

# Configure systemd for running service in users accounts
mkdir -p /etc/systemd/system/user-$user_id.slice.d
cat > /etc/systemd/system/user-$user_id.slice.d/resources.conf <<- EOF
[Slice]
TasksMax=infinity
EOF
mkdir -p /home/$user_name/.config/systemd/
cat > /home/$user_name/.config/systemd/user.conf <<- EOF
[Manager]
DefaultLimitNOFILE=infinity
DefaultLimitNPROC=infinity
EOF
chown $user_name:$user_name /home/$user_name/.config/systemd/user.conf /home/$user_name/.config/systemd /home/$user_name/.config/

systemctl daemon-reload

echo export XDG_RUNTIME_DIR="/run/user/$user_id" >> "/home/$user_name/.bashrc"

# Verify NVIDIA driver and Docker GPU support
echo "=== GPU Info ==="
nvidia-smi || echo "WARNING: nvidia-smi failed"

${install_runner}

# Put the runner work directory (checkout, JIT build outputs, compile cache)
# on the instance-store NVMe too.
if mountpoint -q /opt/dlami/nvme && [ ! -e /opt/actions-runner/_work ]; then
    mkdir -p /opt/dlami/nvme/actions-runner-work
    chown $user_name:$user_name /opt/dlami/nvme/actions-runner-work
    ln -s /opt/dlami/nvme/actions-runner-work /opt/actions-runner/_work
fi

${post_install}

cd /opt/actions-runner

%{ if hook_job_started != "" }
cat > /opt/actions-runner/hook_job_started.sh <<'EOF'
${hook_job_started}
EOF
echo ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/actions-runner/hook_job_started.sh | tee -a /opt/actions-runner/.env
%{ endif }

%{ if hook_job_completed != "" }
cat > /opt/actions-runner/hook_job_completed.sh <<'EOF'
${hook_job_completed}
EOF
echo ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/actions-runner/hook_job_completed.sh | tee -a /opt/actions-runner/.env
%{ endif }

${start_runner}
