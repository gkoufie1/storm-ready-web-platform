#!/usr/bin/env bash
# Flip Emergency Mode for an environment.
#   scripts/emergency.sh staging on|off|status
set -euo pipefail

ENV="${1:?usage: emergency.sh <staging|prod> <on|off|status>}"
MODE="${2:?usage: emergency.sh <staging|prod> <on|off|status>}"
FUNCTION="storm-ready-${ENV}-emergency-mode"
WHO="$(aws sts get-caller-identity --query Arn --output text)"
OUT="$(mktemp)"

aws lambda invoke \
  --function-name "$FUNCTION" \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"mode\": \"${MODE}\", \"requested_by\": \"${WHO}\"}" \
  "$OUT" >/dev/null

python -m json.tool "$OUT"
rm -f "$OUT"
