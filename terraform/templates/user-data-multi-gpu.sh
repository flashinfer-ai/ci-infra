#!/bin/bash
# user-data-multi-gpu.sh
# User-data script for multi-GPU instances (p6-b200.48xlarge, p5.48xlarge)
# Registers multiple GitHub Actions runners (one per GPU) with CUDA_VISIBLE_DEVICES isolation
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

set -euo pipefail

%{ if enable_debug_logging }
set -x
%{ endif }

${pre_install}

echo "=== Multi-GPU Runner Setup Starting ==="
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ============================================================================
# Basic Setup (same as user-data-gpu.sh)
# ============================================================================

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
%{ if enable_cloudwatch_agent }
curl -fsSL -o "/tmp/amazon-cloudwatch-agent.deb" "https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/$(dpkg --print-architecture)/latest/amazon-cloudwatch-agent.deb"
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb
rm -f /tmp/amazon-cloudwatch-agent.deb
amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "ssm:${ssm_key_cloudwatch_agent_config}"
%{ endif }

# Ensure Docker service is running
systemctl enable docker
systemctl start docker

# Add ubuntu user to docker group
usermod -aG docker $user_name

# Configure NVIDIA Container Toolkit
nvidia-ctk runtime configure --runtime=docker

# Configure Docker daemon with nvidia runtime
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

systemctl restart docker

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

# ============================================================================
# GPU Information
# ============================================================================

echo "=== GPU Info ==="
nvidia-smi || { echo "ERROR: nvidia-smi failed"; exit 1; }

NUM_GPUS=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)
echo "Detected $NUM_GPUS GPUs"

if [[ "$NUM_GPUS" -lt 1 ]]; then
    echo "ERROR: No GPUs detected"
    exit 1
fi

# ============================================================================
# Get Instance Metadata (same pattern as start-runner.sh)
# ============================================================================

echo "=== Getting Instance Metadata ==="

# Get IMDSv2 token
token=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

region=$(curl -sH "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
instance_id=$(curl -sH "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id)
instance_type=$(curl -sH "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-type)
availability_zone=$(curl -sH "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/availability-zone)

echo "Region: $region"
echo "Instance ID: $instance_id"
echo "Instance Type: $instance_type"
echo "Availability Zone: $availability_zone"

# Get configuration from instance tags (same as start-runner.sh)
environment=$(curl -sH "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:environment)
ssm_config_path=$(curl -sH "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:ssm_config_path)
runner_name_prefix=$(curl -sH "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:runner_name_prefix || echo "")

echo "Environment: $environment"
echo "SSM Config Path: $ssm_config_path"
echo "Runner Name Prefix: $runner_name_prefix"

# ============================================================================
# Get Runner Configuration from SSM
# ============================================================================

echo "=== Getting Runner Configuration from SSM ==="

parameters=$(aws ssm get-parameters-by-path --path "$ssm_config_path" --region "$region" --query "Parameters[*].{Name:Name,Value:Value}")

run_as=$(echo "$parameters" | jq -r '.[] | select(.Name == "'$ssm_config_path'/run_as") | .Value')
token_path=$(echo "$parameters" | jq -r '.[] | select(.Name == "'$ssm_config_path'/token_path") | .Value')

if [[ -z "$run_as" ]]; then
    run_as="ubuntu"
fi

echo "Run as: $run_as"
echo "Token path: $token_path"

# ============================================================================
# Get Runner Token from SSM (stored by Lambda)
# ============================================================================

echo "=== Getting Runner Token from SSM ==="

config=""
retry_count=0
max_retries=60

while [[ -z "$config" && $retry_count -lt $max_retries ]]; do
    config=$(aws ssm get-parameter \
        --name "$token_path/$instance_id" \
        --with-decryption \
        --region "$region" \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || echo "")

    if [[ -z "$config" ]]; then
        echo "Waiting for config... (attempt $((retry_count + 1))/$max_retries)"
        sleep 5
        retry_count=$((retry_count + 1))
    fi
done

if [[ -z "$config" ]]; then
    echo "ERROR: Failed to get runner config from SSM after $max_retries attempts"
    exit 1
fi

echo "Got runner config from SSM"

# Delete the SSM parameter (it's one-time use)
aws ssm delete-parameter --name "$token_path/$instance_id" --region "$region" || true

# The config format is: --url https://github.com/ORG --token XXXXX --labels label1,label2 ...
# Extract components
runner_url=$(echo "$config" | grep -oP '(?<=--url )[^ ]+' || echo "")
runner_token=$(echo "$config" | grep -oP '(?<=--token )[^ ]+' || echo "")
base_labels=$(echo "$config" | grep -oP '(?<=--labels )[^ ]+' || echo "")

if [[ -z "$runner_token" || -z "$runner_url" ]]; then
    echo "ERROR: Could not extract runner token or URL from config"
    echo "Config received: $config"
    exit 1
fi

echo "Runner URL: $runner_url"
echo "Base Labels: $base_labels"

# ============================================================================
# Install GitHub Actions Runner
# ============================================================================

echo "=== Installing GitHub Actions Runner ==="

RUNNER_BASE_DIR="/opt/actions-runner"
mkdir -p "$RUNNER_BASE_DIR"
cd "$RUNNER_BASE_DIR"

# Download runner from S3 if configured, otherwise from GitHub
%{ if s3_location_runner_distribution != "" }
echo "Downloading runner from S3: ${s3_location_runner_distribution}"
aws s3 cp "${s3_location_runner_distribution}" actions-runner.tar.gz
%{ else }
# Get latest runner version
RUNNER_VERSION=$(curl -sL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/v//')
echo "Downloading runner v$RUNNER_VERSION from GitHub..."
curl -sL -o actions-runner.tar.gz "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
%{ endif }

# ============================================================================
# Configure Multiple Runners (One Per GPU)
# ============================================================================

echo "=== Configuring $NUM_GPUS Runners ==="

for gpu_id in $(seq 0 $((NUM_GPUS - 1))); do
    runner_dir="$RUNNER_BASE_DIR/runner-gpu$gpu_id"
    runner_name="$${runner_name_prefix}gpu$gpu_id-$instance_id"
    gpu_labels="$base_labels,gpu$gpu_id"

    echo "--- Setting up runner for GPU $gpu_id: $runner_name ---"

    # Create runner directory and extract
    mkdir -p "$runner_dir"
    cd "$runner_dir"

    if [[ ! -f "./config.sh" ]]; then
        tar xzf "$RUNNER_BASE_DIR/actions-runner.tar.gz"
    fi

    # Set ownership BEFORE running config.sh as the run_as user
    chown -R "$run_as:$run_as" "$runner_dir"

    # Configure runner (if not already configured)
    if [[ ! -f ".runner" ]]; then
        echo "Configuring runner $runner_name..."
        sudo -u "$run_as" ./config.sh \
            --url "$runner_url" \
            --token "$runner_token" \
            --name "$runner_name" \
            --labels "$gpu_labels" \
            --work "_work" \
            --unattended \
            --replace
    else
        echo "Runner already configured, skipping..."
    fi

    # Create systemd service with GPU binding
    service_name="actions-runner-gpu$gpu_id"
    service_file="/etc/systemd/system/$service_name.service"

    echo "Creating systemd service: $service_name"

    cat > "$service_file" << SYSTEMD_EOF
[Unit]
Description=GitHub Actions Runner (GPU $gpu_id - $runner_name)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=$run_as
WorkingDirectory=$runner_dir
Environment="CUDA_VISIBLE_DEVICES=$gpu_id"
Environment="NVIDIA_VISIBLE_DEVICES=$gpu_id"
ExecStart=$runner_dir/run.sh
Restart=always
RestartSec=10
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

    systemctl daemon-reload
    systemctl enable "$service_name"
done

# Clean up tarball
rm -f "$RUNNER_BASE_DIR/actions-runner.tar.gz"

# ============================================================================
# Start All Runners
# ============================================================================

echo "=== Starting All Runners ==="

for gpu_id in $(seq 0 $((NUM_GPUS - 1))); do
    service_name="actions-runner-gpu$gpu_id"
    echo "Starting $service_name..."
    systemctl start "$service_name"
done

# Wait a moment and verify
sleep 5

echo "=== Runner Status ==="
for gpu_id in $(seq 0 $((NUM_GPUS - 1))); do
    service_name="actions-runner-gpu$gpu_id"
    status=$(systemctl is-active "$service_name" || true)
    echo "GPU $gpu_id ($service_name): $status"
done

${post_install}

echo "=== Multi-GPU Runner Setup Complete ==="
echo "Configured $NUM_GPUS runners on instance $instance_id"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
