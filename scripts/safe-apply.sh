#!/bin/bash
# Copyright 2025 FlashInfer Contributors
# Licensed under the Apache License, Version 2.0

# Safe Terraform Apply Script
# This script prevents terraform apply if the webhook URL would change,
# which would require updating the GitHub App and cause production disruption.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

cd "$TERRAFORM_DIR"

echo "=== FlashInfer CI Infrastructure Safe Apply ==="
echo ""

# Check if terraform is initialized
if [ ! -d ".terraform" ]; then
    echo "Error: Terraform not initialized. Run 'terraform init' first."
    exit 1
fi

# Generate plan
echo "Generating Terraform plan..."
terraform plan -out=tfplan.binary -detailed-exitcode || PLAN_EXIT_CODE=$?

# Exit code 0 = no changes, 1 = error, 2 = changes present
if [ "${PLAN_EXIT_CODE:-0}" -eq 1 ]; then
    echo "Error: Terraform plan failed."
    rm -f tfplan.binary
    exit 1
fi

if [ "${PLAN_EXIT_CODE:-0}" -eq 0 ]; then
    echo "No changes detected. Infrastructure is up to date."
    rm -f tfplan.binary
    exit 0
fi

# Convert to JSON for analysis
echo ""
echo "Analyzing plan for webhook-breaking changes..."
terraform show -json tfplan.binary > tfplan.json

# Check for API Gateway recreation (would change webhook URL)
WEBHOOK_BREAKING_CHANGES=$(jq -r '
  .resource_changes[]? |
  select(.address | test("apigateway|webhook.*api|api.*webhook"; "i")) |
  select(.change.actions | contains(["delete"]) or contains(["create"]) and (contains(["update"]) | not)) |
  "\(.address): \(.change.actions | join(", "))"
' tfplan.json 2>/dev/null || echo "")

if [ -n "$WEBHOOK_BREAKING_CHANGES" ]; then
    echo ""
    echo "============================================================"
    echo "ERROR: WEBHOOK-BREAKING CHANGES DETECTED!"
    echo "============================================================"
    echo ""
    echo "The following changes would recreate API Gateway resources,"
    echo "causing the webhook URL to change. This requires updating"
    echo "the GitHub App configuration and will disrupt production CI."
    echo ""
    echo "Affected resources:"
    echo "$WEBHOOK_BREAKING_CHANGES"
    echo ""
    echo "============================================================"
    echo "APPLY BLOCKED - Manual intervention required"
    echo "============================================================"
    echo ""
    echo "Options:"
    echo "  1. Review and modify your changes to avoid recreation"
    echo "  2. If intentional, use 'terraform apply' directly (not this script)"
    echo "     and update the GitHub App webhook URL after apply"
    echo ""
    rm -f tfplan.binary tfplan.json
    exit 1
fi

echo "No webhook-breaking changes detected."
echo ""

# Show summary of changes
echo "=== Plan Summary ==="
terraform show tfplan.binary | grep -E "^(Plan:|  #|Terraform will)" || true
echo ""

# Prompt for confirmation
read -p "Apply these changes? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Apply cancelled."
    rm -f tfplan.binary tfplan.json
    exit 0
fi

# Apply the plan
echo ""
echo "Applying changes..."
terraform apply tfplan.binary

# Cleanup
rm -f tfplan.binary tfplan.json

echo ""
echo "=== Apply complete ==="
