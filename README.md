# FlashInfer CI Infrastructure

Terraform configuration for FlashInfer's CI infrastructure using GitHub Actions self-hosted runners on AWS.

## Overview

- **Spot/On-demand runners**: Managed by [terraform-aws-github-runner](https://github.com/github-aws-runners/terraform-aws-github-runner) (unmodified upstream as submodule)
- **Capacity Block runners**: Custom infrastructure for H100/B200 GPUs (p5/p6 instances)

## Quick Start

```bash
# Clone with submodules
git clone --recursive https://github.com/flashinfer-ai/flashinfer-ci.git
cd ci-infra

# Set up environment
cp scripts/setup-env.sh.example scripts/setup-env.sh
# Edit setup-env.sh with your values
source scripts/setup-env.sh

# Deploy
cd terraform
terraform init
../scripts/safe-apply.sh  # Recommended: blocks if webhook URL would change
```

## Safety Scripts

- **`scripts/safe-apply.sh`** - Interactive apply that blocks if webhook URL would change
- **`scripts/check-webhook-safety.sh`** - CI-friendly check (exit code 2 = webhook-breaking changes)

These scripts prevent accidental recreation of API Gateway, which would change the webhook URL and require updating the GitHub App configuration.

## License

Apache License 2.0 - see [LICENSE](LICENSE) file for details.
