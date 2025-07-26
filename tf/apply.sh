#!/bin/bash
set -euo pipefail

. ./utils.sh

tfInit
tfApply
gitCommit
