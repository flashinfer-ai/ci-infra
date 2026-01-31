#!/bin/bash -e
# Multi-Runner User Data Script for CB Instances (H100/B200)
# Launches multiple GitHub runners on a single 8-GPU node:
#   - 1x 4-GPU runner (GPUs 0-3)
#   - 4x 1-GPU runners (GPUs 4,5,6,7)
#
# This script is designed for Capacity Block instances where we want
# to maximize utilization of expensive GPU nodes.
#
# NOTE: This is a Terraform templatefile. Terraform variables use dollar-brace syntax,
# bash variables are escaped by doubling the dollar sign.

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# Configuration from terraform
REGION="${region}"
ENVIRONMENT="${environment}"
INSTANCE_TYPE="${instance_type}"
GPU_TYPE="${gpu_type}"  # h100 or b200
SSM_CONFIG_PATH="${ssm_config_path}"
GITHUB_APP_ID_PARAM="${github_app_id_param}"
GITHUB_APP_KEY_PARAM="${github_app_key_param}"
ORG_NAME="${org_name}"
RUNNER_GROUP="${runner_group}"
LABELS_BASE="${labels_base}"

# Derived values
INSTANCE_ID=$$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
RUNNER_BASE_DIR="/opt/actions-runner"

echo "=== Multi-Runner Setup for $$GPU_TYPE ==="
echo "Instance ID: $$INSTANCE_ID"
echo "Instance Type: $$INSTANCE_TYPE"
echo "Environment: $$ENVIRONMENT"

# Install dependencies
apt-get update
apt-get install -y jq curl unzip

# Get GitHub App credentials from SSM
echo "Fetching GitHub App credentials..."
GITHUB_APP_ID=$$(aws ssm get-parameter --name "$$GITHUB_APP_ID_PARAM" --region "$$REGION" --query 'Parameter.Value' --output text)
GITHUB_APP_KEY_BASE64=$$(aws ssm get-parameter --name "$$GITHUB_APP_KEY_PARAM" --region "$$REGION" --with-decryption --query 'Parameter.Value' --output text)
GITHUB_APP_KEY=$$(echo "$$GITHUB_APP_KEY_BASE64" | base64 -d)

# Function to generate JWT for GitHub App
generate_jwt() {
    local app_id=$$1
    local private_key="$$2"
    local now=$$(date +%s)
    local iat=$$((now - 60))
    local exp=$$((now + 600))

    local header=$$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    local payload=$$(echo -n "{\"iat\":$$iat,\"exp\":$$exp,\"iss\":\"$$app_id\"}" | base64 -w 0 | tr '+/' '-_' | tr -d '=')

    local signature=$$(echo -n "$$header.$$payload" | openssl dgst -sha256 -sign <(echo "$$private_key") | base64 -w 0 | tr '+/' '-_' | tr -d '=')

    echo "$$header.$$payload.$$signature"
}

# Function to get installation access token
get_access_token() {
    local jwt=$$(generate_jwt "$$GITHUB_APP_ID" "$$GITHUB_APP_KEY")

    # Get installation ID for the org
    local installations=$$(curl -s -H "Authorization: Bearer $$jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations")

    local installation_id=$$(echo "$$installations" | jq -r ".[] | select(.account.login==\"$$ORG_NAME\") | .id")

    if [ -z "$$installation_id" ]; then
        echo "ERROR: Could not find installation for org $$ORG_NAME" >&2
        exit 1
    fi

    # Get access token
    local token_response=$$(curl -s -X POST \
        -H "Authorization: Bearer $$jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/$$installation_id/access_tokens")

    echo "$$token_response" | jq -r '.token'
}

# Function to get runner registration token
get_registration_token() {
    local access_token=$$1

    local response=$$(curl -s -X POST \
        -H "Authorization: token $$access_token" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/$$ORG_NAME/actions/runners/registration-token")

    echo "$$response" | jq -r '.token'
}

# Function to setup a single runner
setup_runner() {
    local runner_id=$$1
    local runner_name=$$2
    local labels=$$3
    local cuda_devices=$$4
    local registration_token=$$5

    local runner_dir="$$RUNNER_BASE_DIR/runner-$$runner_id"

    echo "Setting up runner $$runner_id: $$runner_name"
    echo "  Labels: $$labels"
    echo "  CUDA_VISIBLE_DEVICES: $$cuda_devices"

    # Create runner directory
    mkdir -p "$$runner_dir"
    cd "$$runner_dir"

    # Download runner if not exists
    if [ ! -f "./config.sh" ]; then
        echo "Downloading GitHub Actions runner..."
        curl -sL https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-x64-2.321.0.tar.gz | tar xz
    fi

    # Configure runner
    ./config.sh --unattended \
        --url "https://github.com/$$ORG_NAME" \
        --token "$$registration_token" \
        --name "$$runner_name" \
        --labels "$$labels" \
        --runnergroup "$$RUNNER_GROUP" \
        --work "_work" \
        --replace

    # Create systemd service with GPU assignment
    cat > /etc/systemd/system/actions-runner-$$runner_id.service << EOFSERVICE
[Unit]
Description=GitHub Actions Runner $$runner_id
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$$runner_dir
Environment="CUDA_VISIBLE_DEVICES=$$cuda_devices"
Environment="NVIDIA_VISIBLE_DEVICES=$$cuda_devices"
ExecStart=$$runner_dir/run.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSERVICE

    # Enable and start service
    systemctl daemon-reload
    systemctl enable actions-runner-$$runner_id
    systemctl start actions-runner-$$runner_id

    echo "Runner $$runner_id started successfully"
}

# Main setup
echo "Getting GitHub access token..."
ACCESS_TOKEN=$$(get_access_token)

if [ -z "$$ACCESS_TOKEN" ] || [ "$$ACCESS_TOKEN" == "null" ]; then
    echo "ERROR: Failed to get access token"
    exit 1
fi

# Define runner configurations
# Format: runner_id:name_suffix:labels:cuda_devices
# Using separate labels for flexibility (e.g., h100 + 4gpu instead of h100-4gpu)
declare -a RUNNERS=(
    "1:4gpu:$$LABELS_BASE,4gpu,multi-gpu:0,1,2,3"
    "2:1gpu-a:$$LABELS_BASE,1gpu:4"
    "3:1gpu-b:$$LABELS_BASE,1gpu:5"
    "4:1gpu-c:$$LABELS_BASE,1gpu:6"
    "5:1gpu-d:$$LABELS_BASE,1gpu:7"
)

echo "Setting up $${#RUNNERS[@]} runners..."

for runner_config in "$${RUNNERS[@]}"; do
    IFS=':' read -r runner_id name_suffix labels cuda_devices <<< "$$runner_config"

    runner_name="$${ENVIRONMENT}-$${GPU_TYPE}-$${name_suffix}-$${INSTANCE_ID}"

    # Get fresh registration token for each runner
    echo "Getting registration token for runner $$runner_id..."
    REG_TOKEN=$$(get_registration_token "$$ACCESS_TOKEN")

    if [ -z "$$REG_TOKEN" ] || [ "$$REG_TOKEN" == "null" ]; then
        echo "ERROR: Failed to get registration token for runner $$runner_id"
        continue
    fi

    setup_runner "$$runner_id" "$$runner_name" "$$labels" "$$cuda_devices" "$$REG_TOKEN"
done

echo "=== Multi-Runner Setup Complete ==="
echo "Runners started:"
systemctl list-units --type=service | grep actions-runner

# Tag instance with runner info
aws ec2 create-tags --region "$$REGION" --resources "$$INSTANCE_ID" --tags \
    Key=ghr:runners,Value="5" \
    Key=ghr:gpu_type,Value="$$GPU_TYPE"

echo "Setup finished at $$(date)"
