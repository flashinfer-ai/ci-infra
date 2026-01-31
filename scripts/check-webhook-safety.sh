#!/bin/bash
# Copyright 2025 FlashInfer Contributors
# Licensed under the Apache License, Version 2.0

# Webhook Safety Check Script (CI-friendly)
# Checks if a terraform plan would change the webhook URL.
# Designed for use in CI/CD pipelines.
#
# Exit codes:
#   0 = Safe to apply (no webhook-breaking changes)
#   1 = Error during check
#   2 = Webhook-breaking changes detected (blocks apply)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
PLAN_FILE="${1:-tfplan.binary}"

cd "$TERRAFORM_DIR"

# If plan file provided as argument and exists, use it
# Otherwise, generate a new plan
if [ ! -f "$PLAN_FILE" ]; then
    echo "Generating Terraform plan..."
    terraform plan -out="$PLAN_FILE" -detailed-exitcode || PLAN_EXIT_CODE=$?

    if [ "${PLAN_EXIT_CODE:-0}" -eq 1 ]; then
        echo "::error::Terraform plan failed"
        exit 1
    fi

    if [ "${PLAN_EXIT_CODE:-0}" -eq 0 ]; then
        echo "No changes detected."
        exit 0
    fi
fi

# Convert to JSON for analysis
echo "Analyzing plan for webhook-breaking changes..."
terraform show -json "$PLAN_FILE" > tfplan.json

# Check for API Gateway recreation
# This includes:
# - aws_apigatewayv2_api (the main API Gateway resource)
# - Any resource with "webhook" and "api" in the name that's being recreated
WEBHOOK_BREAKING=$(jq -e '
  [.resource_changes[]? |
   select(.address | test("apigatewayv2_api|webhook.*api|api.*webhook"; "i")) |
   select(.change.actions as $actions |
     ($actions | contains(["delete"])) or
     (($actions | contains(["create"])) and ($actions | contains(["update"]) | not))
   )] | length > 0
' tfplan.json 2>/dev/null) || WEBHOOK_BREAKING="false"

if [ "$WEBHOOK_BREAKING" = "true" ]; then
    echo ""
    echo "::error::WEBHOOK-BREAKING CHANGES DETECTED"
    echo ""
    echo "The following changes would recreate API Gateway resources:"
    jq -r '
      .resource_changes[]? |
      select(.address | test("apigatewayv2_api|webhook.*api|api.*webhook"; "i")) |
      select(.change.actions as $actions |
        ($actions | contains(["delete"])) or
        (($actions | contains(["create"])) and ($actions | contains(["update"]) | not))
      ) |
      "  - \(.address): \(.change.actions | join(" -> "))"
    ' tfplan.json
    echo ""
    echo "This would change the webhook URL and disrupt production CI."
    echo "Apply is blocked. Review changes or apply manually if intentional."

    rm -f tfplan.json
    exit 2
fi

echo "Webhook safety check passed - no webhook-breaking changes."
rm -f tfplan.json
exit 0
