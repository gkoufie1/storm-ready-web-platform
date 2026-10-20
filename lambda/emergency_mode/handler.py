"""Emergency Mode: one switch that prepares the platform for a traffic surge.

Invoke with {"mode": "on" | "off" | "status", "requested_by": "<who>"}, or
let the CloudFront request-rate alarm invoke it through SNS (alarm events
can only turn emergency mode ON — turning it off is always a human call).

"on" applies the emergency profile:
  * ECS:        raise the min/max task count so capacity is already there
  * Aurora:     raise the minimum ACUs so the database isn't cold or paused
  * CloudFront: raise cache TTLs so almost every request is served at the edge
"off" restores the baseline profile Terraform was deployed with.

Every step is idempotent, so a retry (e.g. SNS redelivery) is always safe.
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

CONFIG = json.loads(os.environ.get("CONFIG", "{}"))

autoscaling = boto3.client("application-autoscaling")
rds = boto3.client("rds")
cloudfront = boto3.client("cloudfront")
ssm = boto3.client("ssm")

VALID_MODES = ("on", "off", "status")


def handler(event, context):
    mode, requested_by = parse_event(event)
    if mode is None:
        logger.info(json.dumps({"skipped": True, "event": event}))
        return {"skipped": True}

    if mode == "status":
        return current_state()

    results = {}
    failed = False
    for name, step in (("ecs", scale_ecs), ("aurora", scale_aurora), ("cloudfront", set_ttls)):
        try:
            results[name] = step(mode)
        except Exception as exc:  # keep going: a partial surge-prep beats none
            logger.exception("step %s failed", name)
            results[name] = f"FAILED: {exc}"
            failed = True

    record = {
        "mode": mode,
        "requested_by": requested_by,
        "changed_at": datetime.now(timezone.utc).isoformat(),
        "results": results,
    }
    ssm.put_parameter(
        Name=CONFIG["parameter_name"],
        Value=json.dumps(record),
        Type="String",
        Overwrite=True,
    )
    logger.info(json.dumps(record))

    if failed:
        # Surface the failure to the caller / SNS so it retries.
        raise RuntimeError(f"Emergency mode '{mode}' partially failed: {json.dumps(results)}")
    return record


def parse_event(event):
    """Return (mode, requested_by), or (None, None) if there's nothing to do."""
    records = event.get("Records") if isinstance(event, dict) else None
    if records:
        message = json.loads(records[0]["Sns"]["Message"])
        if message.get("NewStateValue") == "ALARM":
            return "on", f"alarm:{message.get('AlarmName', 'unknown')}"
        return None, None  # OK / INSUFFICIENT_DATA transitions never turn it off

    mode = str(event.get("mode", "")).lower()
    if mode not in VALID_MODES:
        raise ValueError(f"mode must be one of {VALID_MODES}, got {mode!r}")
    return mode, event.get("requested_by", "manual")


def scale_ecs(mode):
    cfg = CONFIG["ecs"]
    profile = cfg[mode]
    autoscaling.register_scalable_target(
        ServiceNamespace="ecs",
        ResourceId=cfg["resource_id"],
        ScalableDimension="ecs:service:DesiredCount",
        MinCapacity=profile["min"],
        MaxCapacity=profile["max"],
    )
    return f"tasks min={profile['min']} max={profile['max']}"


def scale_aurora(mode):
    cfg = CONFIG["aurora"]
    profile = cfg[mode]
    scaling = {"MinCapacity": profile["min"], "MaxCapacity": profile["max"]}
    if profile["min"] == 0:
        scaling["SecondsUntilAutoPause"] = profile["auto_pause_seconds"]
    rds.modify_db_cluster(
        DBClusterIdentifier=cfg["cluster_id"],
        ServerlessV2ScalingConfiguration=scaling,
        ApplyImmediately=True,
    )
    return f"acu min={profile['min']} max={profile['max']}"


def set_ttls(mode):
    cfg = CONFIG["cloudfront"]
    profile = cfg[mode]
    current = cloudfront.get_cache_policy_config(Id=cfg["cache_policy_id"])
    policy = current["CachePolicyConfig"]
    policy["MinTTL"] = profile["min"]
    policy["DefaultTTL"] = profile["default"]
    policy["MaxTTL"] = profile["max"]
    cloudfront.update_cache_policy(
        Id=cfg["cache_policy_id"],
        IfMatch=current["ETag"],
        CachePolicyConfig=policy,
    )
    return f"ttl min={profile['min']} default={profile['default']} max={profile['max']}"


def current_state():
    stored = ssm.get_parameter(Name=CONFIG["parameter_name"])["Parameter"]["Value"]

    target = autoscaling.describe_scalable_targets(
        ServiceNamespace="ecs",
        ResourceIds=[CONFIG["ecs"]["resource_id"]],
        ScalableDimension="ecs:service:DesiredCount",
    )["ScalableTargets"][0]

    cluster = rds.describe_db_clusters(
        DBClusterIdentifier=CONFIG["aurora"]["cluster_id"]
    )["DBClusters"][0]

    policy = cloudfront.get_cache_policy_config(
        Id=CONFIG["cloudfront"]["cache_policy_id"]
    )["CachePolicyConfig"]

    return {
        "last_change": json.loads(stored),
        "live": {
            "ecs": {"min": target["MinCapacity"], "max": target["MaxCapacity"]},
            "aurora": cluster.get("ServerlessV2ScalingConfiguration", {}),
            "cloudfront_ttl": {
                "min": policy["MinTTL"],
                "default": policy["DefaultTTL"],
                "max": policy["MaxTTL"],
            },
        },
    }
