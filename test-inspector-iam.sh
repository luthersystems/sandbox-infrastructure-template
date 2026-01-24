#!/bin/bash
# Test script to verify GCP inspector service account IAM bindings
# Usage: ./test-inspector-iam.sh <gcp_project_id> <short_project_id>

set -euo pipefail

GCP_PROJECT_ID="${1:-}"
SHORT_PROJECT_ID="${2:-}"

if [[ -z "$GCP_PROJECT_ID" || -z "$SHORT_PROJECT_ID" ]]; then
  echo "Usage: $0 <gcp_project_id> <short_project_id>"
  echo "Example: $0 my-project-123 abc"
  exit 1
fi

INSPECTOR_SA="insideout-inspector-${SHORT_PROJECT_ID}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

echo "Testing IAM bindings for: $INSPECTOR_SA"
echo ""

# Check if service account exists
echo "1. Checking if service account exists..."
if gcloud iam service-accounts describe "$INSPECTOR_SA" --project="$GCP_PROJECT_ID" &>/dev/null; then
  echo "   ✓ Service account exists"
else
  echo "   ✗ Service account not found"
  exit 1
fi

# Check IAM bindings
echo ""
echo "2. Checking IAM bindings..."
REQUIRED_ROLES=(
  "roles/viewer"
  "roles/storage.objectViewer"
  "roles/secretmanager.viewer"
  "roles/run.viewer"
)

MISSING_ROLES=()

for role in "${REQUIRED_ROLES[@]}"; do
  if gcloud projects get-iam-policy "$GCP_PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:${INSPECTOR_SA} AND bindings.role:${role}" \
    --format="value(bindings.role)" | grep -q "^${role}$"; then
    echo "   ✓ $role"
  else
    echo "   ✗ $role (MISSING)"
    MISSING_ROLES+=("$role")
  fi
done

# Check token creator binding
echo ""
echo "3. Checking token creator binding..."
if gcloud iam service-accounts get-iam-policy "$INSPECTOR_SA" \
  --project="$GCP_PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/iam.serviceAccountTokenCreator" \
  --format="value(bindings.members)" | grep -q "serviceAccount:"; then
  echo "   ✓ Token creator binding exists"
else
  echo "   ✗ Token creator binding missing"
  MISSING_ROLES+=("roles/iam.serviceAccountTokenCreator (on SA)")
fi

# Summary
echo ""
if [[ ${#MISSING_ROLES[@]} -eq 0 ]]; then
  echo "✅ All IAM bindings are correct!"
  exit 0
else
  echo "❌ Missing roles:"
  for role in "${MISSING_ROLES[@]}"; do
    echo "   - $role"
  done
  exit 1
fi
