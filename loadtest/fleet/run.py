"""Run the distributed surge test on the fleet and collect the evidence.

Starts k6 on every generator at the same moment (via SSM), waits for the
run to finish, aggregates the per-generator k6 summaries, and — if given the
distribution ID — pulls CloudFront's own per-minute request count from
CloudWatch, which is the independent number to quote in the bid.

    python loadtest/fleet/run.py --base-url https://demo.epixdevo.org \
        --token <loadtest_token> --distribution-id <staging distribution_id>

Options: --rps 18000 (fleet total, req/s)  --ramp 2m  --hold 10m
Results are written to loadtest/results/<run-id>.json (gitignored).
"""

import argparse
import json
import pathlib
import shlex
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

import boto3

HERE = pathlib.Path(__file__).resolve().parent
RESULTS_DIR = HERE.parent / "results"
DONE = {"Success", "Failed", "Cancelled", "TimedOut"}


def tf_outputs():
    out = subprocess.run(
        ["terraform", f"-chdir={HERE}", "output", "-json"],
        check=True, capture_output=True, text=True,
    ).stdout
    outputs = {k: v["value"] for k, v in json.loads(out).items()}
    if not outputs:
        sys.exit("No fleet outputs — run `terraform apply` in loadtest/fleet first.")
    return outputs


def seconds(duration):
    """'10m' -> 600, '90s' -> 90."""
    unit = duration[-1]
    return int(duration[:-1]) * {"s": 1, "m": 60, "h": 3600}[unit]


def wait_for_ssm(instances):
    """Block until every generator has registered with SSM."""
    deadline = time.time() + 600
    while True:
        online = 0
        for region, ids in instances.items():
            info = boto3.client("ssm", region_name=region).describe_instance_information(
                Filters=[{"Key": "InstanceIds", "Values": ids}]
            )["InstanceInformationList"]
            online += sum(1 for i in info if i["PingStatus"] == "Online")
        total = sum(len(ids) for ids in instances.values())
        print(f"  generators online in SSM: {online}/{total}")
        if online == total:
            return
        if time.time() > deadline:
            sys.exit("Generators did not come online within 10 minutes.")
        time.sleep(15)


def build_commands(args, per_generator_rps, bucket, run_id):
    env = {
        "BASE_URL": args.base_url.rstrip("/"),
        "RATE": str(per_generator_rps),
        "RAMP": args.ramp,
        "HOLD": args.hold,
        "TOKEN": args.token,
    }
    env_flags = " ".join(f"-e {k}={shlex.quote(v)}" for k, v in env.items())
    dest = f"s3://{bucket}/{run_id}"
    return [
        "set -u",
        "while [ ! -f /opt/loadtest/ready ]; do sleep 5; done",
        "ulimit -n 1048576",
        "cd /opt/loadtest",
        "ID=$(cat /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null || hostname)",
        f"k6 run --quiet {env_flags} arrival.js > k6.log 2>&1; echo \"k6 exit $?\" >> k6.log",
        f"aws s3 cp summary.json {dest}/$ID.json --region us-east-1",
        f"aws s3 cp k6.log {dest}/$ID.log --region us-east-1",
    ]


def run(instances, commands, timeout):
    command_ids = {}
    for region, ids in instances.items():
        resp = boto3.client("ssm", region_name=region).send_command(
            InstanceIds=ids,
            DocumentName="AWS-RunShellScript",
            Comment="storm-ready surge test",
            Parameters={"commands": commands, "executionTimeout": [str(timeout)]},
        )
        command_ids[region] = resp["Command"]["CommandId"]

    started = time.time()
    while True:
        statuses = {}
        for region, cid in command_ids.items():
            cmd = boto3.client("ssm", region_name=region).list_commands(CommandId=cid)["Commands"][0]
            statuses[region] = cmd["Status"]
        elapsed = int(time.time() - started)
        print(f"  [{elapsed // 60:02d}:{elapsed % 60:02d}] " +
              "  ".join(f"{r}={s}" for r, s in statuses.items()))
        if all(s in DONE for s in statuses.values()):
            return statuses
        time.sleep(30)


def collect(bucket, run_id):
    s3 = boto3.client("s3", region_name="us-east-1")
    listing = s3.list_objects_v2(Bucket=bucket, Prefix=f"{run_id}/").get("Contents", [])
    summaries = {}
    for obj in listing:
        if obj["Key"].endswith(".json"):
            body = s3.get_object(Bucket=bucket, Key=obj["Key"])["Body"].read()
            summaries[obj["Key"].split("/")[-1][:-5]] = json.loads(body)
    return summaries


def aggregate(summaries):
    rows, total_reqs, total_failed, hits, hit_samples = [], 0, 0, 0, 0
    worst = {"p(95)": 0.0, "p(99)": 0.0}
    for gen, data in sorted(summaries.items()):
        m = data["metrics"]
        reqs = int(m["http_reqs"]["values"]["count"])
        failed = int(m["http_req_failed"]["values"].get("passes", 0))
        dur = m["http_req_duration"]["values"]
        edge = m.get("edge_cache_hit", {}).get("values", {})
        total_reqs += reqs
        total_failed += failed
        hits += edge.get("passes", 0)
        hit_samples += edge.get("passes", 0) + edge.get("fails", 0)
        for k in worst:
            worst[k] = max(worst[k], dur.get(k, 0.0))
        rows.append((gen, reqs, failed, dur.get("p(95)", 0.0), dur.get("p(99)", 0.0)))

    print("\n  generator              requests    failed     p95 ms    p99 ms")
    for gen, reqs, failed, p95, p99 in rows:
        print(f"  {gen:<20} {reqs:>10,} {failed:>9,} {p95:>10.1f} {p99:>9.1f}")

    result = {
        "generators": len(rows),
        "total_requests": total_reqs,
        "failed_requests": total_failed,
        "error_rate_pct": round(100 * total_failed / total_reqs, 4) if total_reqs else None,
        "worst_generator_p95_ms": round(worst["p(95)"], 1),
        "worst_generator_p99_ms": round(worst["p(99)"], 1),
        "edge_cache_hit_pct": round(100 * hits / hit_samples, 2) if hit_samples else None,
    }
    return result


def cloudfront_evidence(distribution_id, start, end):
    """CloudFront's own count of requests per minute — independent of k6."""
    print("\n  Waiting 5 minutes for CloudFront metrics to land in CloudWatch...")
    time.sleep(300)
    cw = boto3.client("cloudwatch", region_name="us-east-1")
    dims = [{"Name": "DistributionId", "Value": distribution_id}, {"Name": "Region", "Value": "Global"}]

    def series(metric, stat):
        points = cw.get_metric_statistics(
            Namespace="AWS/CloudFront", MetricName=metric, Dimensions=dims,
            StartTime=start, EndTime=end + timedelta(minutes=5), Period=60, Statistics=[stat],
        )["Datapoints"]
        return sorted(points, key=lambda p: p["Timestamp"])

    requests = series("Requests", "Sum")
    errors = series("5xxErrorRate", "Average")
    if not requests:
        print("  No CloudFront datapoints yet — re-check in CloudWatch later.")
        return {}
    per_minute = [int(p["Sum"]) for p in requests]
    return {
        "peak_requests_per_minute": max(per_minute),
        "minutes_at_or_above_1M": sum(1 for v in per_minute if v >= 1_000_000),
        "max_5xx_error_rate_pct": round(max((p["Average"] for p in errors), default=0.0), 4),
        "requests_per_minute_series": per_minute,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--token", required=True, help="The loadtest_token set in envs/staging/terraform.tfvars")
    ap.add_argument("--rps", type=int, default=18000, help="Fleet-wide target requests/second")
    ap.add_argument("--ramp", default="2m")
    ap.add_argument("--hold", default="10m")
    ap.add_argument("--distribution-id", help="Staging CloudFront distribution, for CloudWatch evidence")
    args = ap.parse_args()

    outputs = tf_outputs()
    instances = {r: ids for r, ids in outputs["instances"].items() if ids}
    bucket = outputs["results_bucket"]
    generators = sum(len(ids) for ids in instances.values())
    per_generator = max(1, round(args.rps / generators))
    run_id = datetime.now(timezone.utc).strftime("run-%Y%m%dT%H%M%SZ")
    timeout = 120 + seconds(args.ramp) + seconds(args.hold) + 600

    print(f"Run {run_id}: {generators} generators x {per_generator:,} req/s "
          f"= {generators * per_generator:,} req/s ({generators * per_generator * 60:,}/min) "
          f"against {args.base_url}")
    wait_for_ssm(instances)

    start = datetime.now(timezone.utc)
    statuses = run(instances, build_commands(args, per_generator, bucket, run_id), timeout)
    end = datetime.now(timezone.utc)

    summaries = collect(bucket, run_id)
    if not summaries:
        sys.exit(f"No summaries uploaded (SSM status: {statuses}). Check logs under s3://{bucket}/{run_id}/")
    result = {"run_id": run_id, "target_rps": generators * per_generator, "k6": aggregate(summaries)}
    if args.distribution_id:
        result["cloudfront"] = cloudfront_evidence(args.distribution_id, start, end)

    RESULTS_DIR.mkdir(exist_ok=True)
    out = RESULTS_DIR / f"{run_id}.json"
    out.write_text(json.dumps(result, indent=2))
    print("\n" + json.dumps({k: v for k, v in result.items()}, indent=2))
    print(f"\nSaved to {out}")


if __name__ == "__main__":
    main()
