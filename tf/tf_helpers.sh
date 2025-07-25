#!/bin/bash
# tf_helpers.sh
# Helper functions for reading terraform variables from multiple JSON files in auto-vars/

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

AUTO_VARS_DIR="${PROJECT_ROOT}/auto-vars"

# getTfVar VAR_NAME
#   Print the value of VAR_NAME from any JSON file in auto-vars/ or empty string if not found
getTfVar() {
  local key="$1"

  if [[ ! -d "$AUTO_VARS_DIR" ]]; then
    echo "ERROR: Terraform auto vars directory '$AUTO_VARS_DIR' not found" >&2
    echo ""
    exit 1
  fi

  # jq filter to get the variable from any JSON file in the directory, first match wins
  local result=""
  for file in "$AUTO_VARS_DIR"/*.json; do
    # skip if no matching files
    [[ -e "$file" ]] || continue

    val=$(jq -r --arg k "$key" 'if has($k) then .[$k] else empty end' "$file" 2>/dev/null || echo "")
    if [[ -n "$val" ]]; then
      result="$val"
      break
    fi
  done

  echo "${result:-}"
}

# mustGetTfVar VAR_NAME
#   Print the value of VAR_NAME from auto-vars or exit if not set/empty
mustGetTfVar() {
  local val
  val="$(getTfVar "$1")"
  if [[ -z "$val" || "$val" == "null" ]]; then
    echo "ERROR: required terraform variable '$1' missing or empty in $AUTO_VARS_DIR" >&2
    exit 1
  fi
  echo "$val"
}
