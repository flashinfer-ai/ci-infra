#!/bin/bash
# Check if terraform plan would change the webhook URL.
# Exit codes: 0 = safe, 1 = error, 2 = webhook-breaking changes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
PLAN_FILE="${1:-tfplan.binary}"

cd "$TERRAFORM_DIR"

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

echo "Analyzing plan for webhook-breaking changes..."
terraform show -json "$PLAN_FILE" > tfplan.json

WEBHOOK_BREAKING=$(jq -e '
  [.resource_changes[]? |
   select(.address | test("apigatewayv2_api|webhook.*api|api.*webhook"; "i")) |
   select(.change.actions as $actions |
     ($actions | contains(["delete"])) or
     (($actions | contains(["create"])) and ($actions | contains(["update"]) | not))
   )] | length > 0
' tfplan.json 2>/dev/null) || WEBHOOK_BREAKING="false"

if [ "$WEBHOOK_BREAKING" = "true" ]; then
    echo "::error::WEBHOOK-BREAKING CHANGES DETECTED"
    echo "Affected resources:"
    jq -r '
      .resource_changes[]? |
      select(.address | test("apigatewayv2_api|webhook.*api|api.*webhook"; "i")) |
      select(.change.actions as $actions |
        ($actions | contains(["delete"])) or
        (($actions | contains(["create"])) and ($actions | contains(["update"]) | not))
      ) |
      "  - \(.address): \(.change.actions | join(" -> "))"
    ' tfplan.json
    rm -f tfplan.json
    exit 2
fi

echo "Webhook safety check passed."
rm -f tfplan.json
exit 0
