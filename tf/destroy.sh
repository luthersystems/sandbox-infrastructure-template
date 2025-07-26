#!/bin/bash
set -euo pipefail

. ./utils.sh

tfInit
tfDestroy
gitCommit
