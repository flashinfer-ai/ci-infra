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
terraform plan
terraform apply
```

## License

Apache License 2.0 - see [LICENSE](LICENSE) file for details.
