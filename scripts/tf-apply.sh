#!/bin/bash
# Terraform apply with webhook safety check

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

cd "$TERRAFORM_DIR"

echo "FlashInfer CI - Terraform Apply"

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
    echo "ERROR: Webhook-breaking changes detected. Apply blocked."
    echo "Affected resources:"
    echo "$WEBHOOK_BREAKING_CHANGES"
    rm -f tfplan.binary tfplan.json
    exit 1
fi

echo "No webhook-breaking changes detected."

# Show summary of changes
echo "Plan Summary:"
terraform show tfplan.binary | grep -E "^(Plan:|  #|Terraform will)" || true

# Prompt for confirmation
read -p "Apply these changes? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Apply cancelled."
    rm -f tfplan.binary tfplan.json
    exit 0
fi

# Apply the plan
echo "Applying changes..."
terraform apply tfplan.binary

# Cleanup
rm -f tfplan.binary tfplan.json

echo "Apply complete."
