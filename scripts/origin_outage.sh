#!/usr/bin/env bash
# Simulate a total CMS outage (and recover from it) to prove static failover.
#   scripts/origin_outage.sh staging start   # suspend scaling, stop all tasks
#   scripts/origin_outage.sh staging end     # resume scaling, restore capacity
#
# Scaling must be suspended first, or Application Auto Scaling would just
# start the tasks again to satisfy its minimum.
set -euo pipefail

ENV="${1:?usage: origin_outage.sh <staging|prod> <start|end>}"
ACTION="${2:?usage: origin_outage.sh <staging|prod> <start|end>}"
CLUSTER="storm-ready-${ENV}-cluster"
SERVICE="storm-ready-${ENV}-cms"
RESOURCE="service/${CLUSTER}/${SERVICE}"

set_suspended() {
  aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --scalable-dimension ecs:service:DesiredCount \
    --resource-id "$RESOURCE" \
    --suspended-state "DynamicScalingInSuspended=$1,DynamicScalingOutSuspended=$1,ScheduledScalingSuspended=$1"
}

case "$ACTION" in
  start)
    set_suspended true
    aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 >/dev/null
    echo "CMS stopping. Within ~30s the ALB returns 503 and CloudFront serves the S3 snapshot."
    echo "Cached pages keep serving from the edge; to force an origin fetch, add a query string (/?v=\$RANDOM)."
    ;;
  end)
    MIN=$(aws application-autoscaling describe-scalable-targets \
      --service-namespace ecs --resource-ids "$RESOURCE" \
      --query 'ScalableTargets[0].MinCapacity' --output text)
    aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count "$MIN" >/dev/null
    set_suspended false
    echo "CMS restarting with $MIN task(s); scaling resumed."
    ;;
  *)
    echo "action must be start or end" >&2; exit 2 ;;
esac
