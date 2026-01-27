# FlashInfer CI GPU Types

This document describes the GPU runner configurations for FlashInfer CI.

## Active GPU Runners

| Config File | GPU | AWS Instance | SM | Architecture | Labels |
|-------------|-----|--------------|-----|--------------|--------|
| gpu-g4dn.yaml | T4 | g4dn.xlarge | SM75 | Turing | gpu, nvidia, t4, sm75, turing |
| gpu-g5.yaml | A10G | g5.xlarge | SM86 | Ampere | gpu, nvidia, a10g, sm86, ampere |

## Planned GPU Runners

| Config File | GPU | AWS Instance | SM | Architecture | Labels | ETA |
|-------------|-----|--------------|-----|--------------|--------|-----|
| gpu-p4d.yaml | A100 | p4d.24xlarge | SM80 | Ampere | gpu, nvidia, a100, sm80, ampere | TBD |
| gpu-p5.yaml | H100 | p5.48xlarge | SM90 | Hopper | gpu, nvidia, h100, sm90, hopper | TBD |
| gpu-b200.yaml | B200 | TBD | SM100 | Blackwell | gpu, nvidia, b200, sm100, blackwell | TBD |

## Label Strategy

Each GPU runner has multiple labels for flexible workflow targeting:

- `gpu` - Any GPU runner
- `nvidia` - NVIDIA GPU (for future AMD support)
- `<model>` - Specific GPU model (t4, a10g, a100, h100, b200)
- `sm<XX>` - SM version (sm75, sm80, sm86, sm90, sm100)
- `<arch>` - Architecture family (turing, ampere, hopper, blackwell)

### Workflow Targeting Examples

```yaml
# Any GPU
runs-on: [self-hosted, linux, x64, gpu]

# Specific SM version
runs-on: [self-hosted, linux, x64, gpu, sm90]

# Architecture family (all Ampere GPUs: A10G + A100)
runs-on: [self-hosted, linux, x64, gpu, ampere]

# Specific model
runs-on: [self-hosted, linux, x64, gpu, h100]
```

## Adding a New GPU Type

### Step 1: Create YAML Config

Copy an existing `gpu-*.yaml` file and update:

```yaml
# Example: gpu-p5.yaml for H100
matcherConfig:
  exactMatch: true
  labelMatchers:
    - [self-hosted, linux, x64, gpu, sm90]
    - [self-hosted, linux, x64, gpu, h100]
    - [self-hosted, linux, x64, gpu, hopper]
  priority: 1
fifo: true

runner_config:
  runner_os: linux
  runner_architecture: x64
  runner_name_prefix: flashinfer-gpu-p5-
  
  runner_extra_labels:
    - gpu
    - nvidia
    - h100
    - sm90
    - hopper
  
  instance_types:
    - p5.48xlarge
  
  # ... rest of config similar to gpu-g5.yaml
```

### Step 2: Deploy

```bash
cd terraform-aws-github-runner/examples/flashinfer
terraform plan
terraform apply
```

### Step 3: Update Workflows

Add the new GPU to `.github/gpu-matrix.json` in the FlashInfer repository.

## Deprecating a GPU Type

### Step 1: Update Workflows

Remove the GPU from `.github/gpu-matrix.json` to stop new jobs from targeting it.

### Step 2: Wait for Running Jobs

Allow any running jobs on that GPU type to complete.

### Step 3: Remove Config

Delete the YAML file (e.g., `gpu-g4dn.yaml`).

### Step 4: Deploy

```bash
terraform apply
```

## Instance Type Notes

### G4dn (T4)
- 16GB GPU memory
- Good for: SM75-specific tests, cost-effective testing
- Spot pricing: ~$0.16/hr (us-west-2)

### G5 (A10G)
- 24GB GPU memory
- Good for: Primary GPU testing, SM86 architecture
- Spot pricing: ~$0.50/hr (us-west-2)

### P4d (A100) - Planned
- 40GB or 80GB GPU memory
- Good for: Large model testing, SM80 architecture
- Spot pricing: ~$10/hr (us-west-2)

### P5 (H100) - Planned
- 80GB GPU memory
- Good for: Hopper-specific features, SM90 architecture
- Spot pricing: ~$15/hr (us-west-2)

## AMI Configuration

All GPU runners use the AWS Deep Learning AMI which includes:
- NVIDIA drivers (latest stable)
- CUDA toolkit
- Docker with NVIDIA container runtime
- Common ML frameworks

AMI owner ID: `898082745236` (AWS)

To use a custom AMI instead:

```yaml
ami:
  owners:
    - "YOUR_ACCOUNT_ID"
  filter:
    name:
      - "your-custom-ami-name-*"
    state:
      - available
```
