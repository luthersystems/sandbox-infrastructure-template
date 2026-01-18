# GCP Support for sandbox-infrastructure-template

This document describes how to configure and deploy infrastructure to GCP using the sandbox-infrastructure-template.

## Prerequisites

- **Mars v0.92.0 or later** - Required for GCP provider support
- A GCP project with appropriate APIs enabled
- A GCP service account with permissions to create infrastructure

## Configuration

### Terraform Variables

The following variables must be set in `tf/auto-vars/common.auto.tfvars.json` (or any `*.json` file in the `auto-vars/` directory):

#### Required for GCP Deployments

| Variable | Type | Description |
|----------|------|-------------|
| `cloud_provider` | string | Must be set to `"gcp"` |
| `gcp_project_id` | string | The GCP project ID (e.g., `"my-project-123"`) |
| `gcp_region` | string | The GCP region (e.g., `"us-central1"`) |
| `gcp_credentials_b64` | string | Base64-encoded service account JSON key |

#### Example Configuration

```json
{
  "cloud_provider": "gcp",
  "gcp_project_id": "luther-prod-123456",
  "gcp_region": "us-central1",
  "gcp_credentials_b64": "eyJ0eXBlIjoic2VydmljZV9hY2NvdW50Ii..."
}
```

### Generating the Service Account Key

1. Create a service account in your GCP project with the required permissions
2. Generate a JSON key for the service account
3. Base64-encode the key:

```bash
# On macOS/Linux
base64 -i service-account-key.json | tr -d '\n'

# Or using jq to ensure it's compact first
cat service-account-key.json | jq -c . | base64 | tr -d '\n'
```

4. Set the resulting string as the `gcp_credentials_b64` value

> **Security Note:** The `gcp_credentials_b64` value contains sensitive credentials. Ensure it is stored securely and never logged or exposed in plaintext.

## How It Works

### Credential Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        tf/apply.sh                              │
│                             │                                   │
│                             ▼                                   │
│                        tf/utils.sh                              │
│                             │                                   │
│                             ▼                                   │
│                   tf/run-with-creds.sh                          │
│                             │                                   │
│              ┌──────────────┴──────────────┐                    │
│              │                             │                    │
│              ▼                             ▼                    │
│     cloud_provider=gcp            cloud_provider=aws            │
│              │                             │                    │
│              ▼                             ▼                    │
│   setupGCPCredentials()          JUMP_ROLE_ARN logic            │
│   - Decode base64 key            - aws sts assume-role          │
│   - Write to temp file                                          │
│   - Set GOOGLE_APPLICATION_CREDENTIALS                          │
│              │                             │                    │
│              └──────────────┬──────────────┘                    │
│                             │                                   │
│                             ▼                                   │
│                      /opt/mars/run.sh                           │
│                             │                                   │
│                             ▼                                   │
│                         terraform                               │
└─────────────────────────────────────────────────────────────────┘
```

### Environment Variables Set for GCP

When `cloud_provider` is `"gcp"`, the following environment variables are exported before running Terraform:

| Variable | Value |
|----------|-------|
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to temporary credentials file |
| `GOOGLE_PROJECT` | Value of `gcp_project_id` from tfvars |
| `GOOGLE_REGION` | Value of `gcp_region` from tfvars |

### Credential Cleanup

The temporary credentials file is automatically cleaned up:
- On successful completion of the terraform command
- On script exit (via `trap`)
- On error conditions

The file is created with `chmod 600` permissions and uses `mktemp` for unique naming.

## Mars Version Requirement

Update `.mars-version` to use Mars v0.92.0 or later:

```
v0.92.0
```

Mars v0.92.0 includes:
- Google Terraform provider support
- GCP authentication helpers
- Multi-cloud terraform state backend support

## Backward Compatibility

### AWS Deployments

Existing AWS deployments continue to work without any changes:

- If `cloud_provider` is not set, it defaults to `"aws"`
- AWS uses IRSA (IAM Roles for Service Accounts) or `JUMP_ROLE_ARN` as before
- No GCP-specific variables are required for AWS deployments

### Example AWS Configuration (unchanged)

```json
{
  "aws_region": "us-east-1",
  "bootstrap_role": "arn:aws:iam::123456789:role/TerraformRole"
}
```

## Shell Utility Functions

The following functions are available in `shell_utils.sh` for use in custom scripts:

### Cloud Detection

```bash
source shell_utils.sh

# Get the cloud provider (returns "aws" or "gcp")
cloud=$(getCloudProvider)

# Boolean checks
if isGCP; then
  echo "Deploying to GCP"
fi

if isAWS; then
  echo "Deploying to AWS"
fi
```

### Manual Credential Setup

```bash
source shell_utils.sh

# Setup cloud environment (call before terraform)
setupCloudEnv || exit 1

# Register cleanup handler
trap 'cleanupCloudEnv' EXIT

# Run terraform commands...
terraform init
terraform apply
```

## Troubleshooting

### Error: gcp_credentials_b64 not found in tfvars

Ensure the `gcp_credentials_b64` variable is set in a JSON file in `tf/auto-vars/`.

### Error: Failed to decode gcp_credentials_b64

The base64 encoding may be corrupted. Re-encode the service account key:

```bash
base64 -i service-account-key.json | tr -d '\n'
```

### Error: Invalid service account key format

The decoded JSON must be a valid GCP service account key with `"type": "service_account"`. Verify your key file:

```bash
cat service-account-key.json | jq '.type'
# Should output: "service_account"
```

### Error: gcp_project_id or gcp_region not found

Both `gcp_project_id` and `gcp_region` are required for GCP deployments. Add them to your tfvars JSON.

## Integration with ui-core

When ui-core provisions a GCP deployment, it should:

1. Set `cloud_provider` to `"gcp"` in the tfvars
2. Provide the GCP project ID and region
3. Base64-encode the service account key and set `gcp_credentials_b64`
4. Ensure the infrastructure template uses Mars v0.92.0+

The existing terraform lifecycle scripts (`apply.sh`, `plan.sh`, `destroy.sh`) will automatically detect GCP and configure credentials appropriately.
