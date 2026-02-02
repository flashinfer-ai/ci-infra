# FlashInfer CI Infrastructure

Infrastructure-as-code for [FlashInfer](https://github.com/flashinfer-ai/flashinfer)'s public CI system. This repository manages:

- **AWS Infrastructure**: VPC, subnets, security groups, IAM roles
- **Self-Hosted Runners**: GitHub Actions runners on EC2 (spot, on-demand, capacity blocks)
- **Automation**: Lambda functions for runner scaling, cleanup, and management
- **CI/CD**: Automated deployment via GitHub Actions with environment protection

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub (flashinfer-ai/flashinfer)                              │
│    └── Webhook ──► API Gateway ──► Lambda (scale-up)            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  AWS (us-west-2)                                                │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  VPC (10.0.0.0/16)                                      │    │
│  │  ├── Public Subnets  ──► Runners (spot/on-demand)       │    │
│  │  └── Public Subnets  ──► CB Runners (H100/B200)         │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Lambda Functions                                       │    │
│  │  ├── scale-up        (launch runners on job queue)      │    │
│  │  ├── scale-down      (terminate idle runners)           │    │
│  │  ├── cb-scale-up     (launch CB runners)                │    │
│  │  └── cb-manager      (check CB status)                  │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Clone with submodules
git clone --recursive https://github.com/flashinfer-ai/ci-infra.git
cd ci-infra

# Set up environment
cp scripts/setup-env.sh.example scripts/setup-env.sh
# Edit setup-env.sh with your AWS credentials and GitHub App secrets
source scripts/setup-env.sh

# Deploy
cd terraform
terraform init
terraform plan
terraform apply
```

## Available Runners

All runners are registered at the organization level and available to all repositories in [flashinfer-ai](https://github.com/flashinfer-ai).

### Spot Runners (Cost-Optimized)

| Type | GPU | `runs-on` Labels | Instance Types |
|------|-----|------------------|----------------|
| CPU x64 | - | `[self-hosted, linux, x64, cpu, spot]` | r5/r6a/r6i/r7a/r7i (12-16xlarge), m5/m6a/m6i/m7a/m7i (24xlarge) |
| CPU ARM64 | - | `[self-hosted, linux, arm64, cpu, spot]` | r6g/r7g/r8g (8-16xlarge), m6g/m7g (16-24xlarge) |
| GPU T4 | SM75 | `[self-hosted, linux, x64, gpu, sm75, spot]` | g4dn (2xlarge, 4xlarge, 8xlarge) |
| GPU A10G | SM86 | `[self-hosted, linux, x64, gpu, sm86, spot]` | g5 (2xlarge, 4xlarge, 8xlarge) |

### On-Demand Runners (Reliable)

| Type | GPU | `runs-on` Labels | Instance Types |
|------|-----|------------------|----------------|
| CPU x64 | - | `[self-hosted, linux, x64, cpu, on-demand]` | r6a/r6i/r7a/r7i (16xlarge), m6a/m6i (24xlarge) |
| CPU ARM64 | - | `[self-hosted, linux, arm64, cpu, on-demand]` | r6g/r7g/r8g (16xlarge), m6g/m7g (24xlarge) |
| GPU T4 | SM75 | `[self-hosted, linux, x64, gpu, sm75, on-demand]` | g4dn (2xlarge, 4xlarge, 8xlarge) |
| GPU A10G | SM86 | `[self-hosted, linux, x64, gpu, sm86, on-demand]` | g5 (2xlarge, 4xlarge, 8xlarge) |

**Capacity Block Runners**:

| Type | GPU | `runs-on` Labels | Instance |
|------|-----|------------------|----------|
| H100 1-GPU | SM90 | `[self-hosted, linux, x64, gpu, h100, 1gpu]` | p5.48xlarge |
| H100 4-GPU | SM90 | `[self-hosted, linux, x64, gpu, h100, 4gpu]` | p5.48xlarge |
| B200 1-GPU | SM100 | `[self-hosted, linux, x64, gpu, b200, 1gpu]` | p6-b200.48xlarge |
| B200 4-GPU | SM100 | `[self-hosted, linux, x64, gpu, b200, 4gpu]` | p6-b200.48xlarge |

Each p5/p6 node runs 5 runners: 1x 4-GPU runner + 4x 1-GPU runners.

See `terraform/templates/runner-configs/*.yaml` for the full list of instance types.

## License

Apache License 2.0 - see [LICENSE](LICENSE) file for details.
