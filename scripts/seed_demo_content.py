"""Seed the demo site after a fresh deploy: install WordPress, create the
agency pages, and set the options the demo relies on — one command.

Runs as a one-off ECS task from the CMS's own task definition, so it has the
database credentials and network path the site uses. No SSH, no Session
Manager plugin. Safe to re-run: it only creates what's missing.

    python scripts/seed_demo_content.py --env staging --email you@epixdevo.org

On a fresh install it creates a randomly named administrator and prints the
username and password once — save them in your password manager.
"""

import argparse
import base64
import secrets
import sys
import time

import boto3

SEED_SCRIPT = r"""
set -euo pipefail
cd /usr/src/wordpress
# The image's entrypoint only writes wp-config.php when starting Apache.
[ -f wp-config.php ] || cp wp-config-docker.php wp-config.php
curl -fsSLo /tmp/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
wp() { php /tmp/wp --allow-root --path=/usr/src/wordpress --skip-plugins --skip-themes "$@"; }

# Staging's Aurora auto-pauses when idle; give it time to resume.
for i in $(seq 1 24); do
  php -r '$m = @new mysqli(getenv("WORDPRESS_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD"), getenv("WORDPRESS_DB_NAME")); exit($m->connect_errno ? 1 : 0);' && break
  [ "$i" = 24 ] && { echo "SEED: database did not become reachable"; exit 1; }
  echo "SEED: waiting for the database to resume..."; sleep 5
done

if ! wp core is-installed 2>/dev/null; then
  wp core install --url="$SITE_URL" --title="SC Emergency Information (Demo)" \
    --admin_user="$SEED_USER" --admin_password="$SEED_PASS" --admin_email="$SEED_EMAIL" --skip-email
  wp user update "$SEED_USER" --display_name="SC Emergency Information" --nickname="SC Emergency Information"
  echo "SEED: installed WordPress with a new administrator"
else
  echo "SEED: WordPress already installed; existing users kept"
fi

wp option update blog_public 0
wp option update blogdescription "Demonstration site - not an official source"
wp rewrite structure '/%postname%/'

for slug in sample-page hello-world; do
  for id in $(wp post list --post_type=post,page --post_status=any --name="$slug" --field=ID); do
    wp post delete "$id" --force >/dev/null && echo "SEED: removed default $slug"
  done
done

DEMO='<p><strong>DEMO SITE - not an official source.</strong></p>'
page() {
  if [ -z "$(wp post list --post_type=page --name="$1" --field=ID)" ]; then
    wp post create --post_type=page --post_status=publish --post_name="$1" --post_title="$2" \
      --menu_order="$4" --post_content="$DEMO$3" --porcelain >/dev/null
    echo "SEED: created /$1/"
  else
    echo "SEED: /$1/ already exists"
  fi
}

page home "SC Emergency Information" "<p>Current emergency information for South Carolina residents. During an active event this site is updated as conditions change.</p><ul><li><a href=\"/evacuation-routes/\">Evacuation Routes</a></li><li><a href=\"/shelter-locations/\">Shelter Locations</a></li><li><a href=\"/road-closures/\">Road Closures</a></li><li><a href=\"/contact/\">Contact</a></li></ul>" 0
page evacuation-routes "Evacuation Routes" "<p>Coastal evacuation routes are in effect for Zones A and B. Use the designated routes inland and follow directions from law enforcement. Lane reversals may be in place on major corridors. Check Road Closures before you leave.</p>" 1
page shelter-locations "Shelter Locations" "<p>General population shelters open at 6:00 PM. Bring medications, ID, bedding, and enough food and water for three days. Pet-friendly shelters are marked below. Shelters are not able to provide cots for everyone.</p>" 2
page road-closures "Road Closures" "<p>This page is updated every 30 minutes during an active event. Closed roads are listed by county. Do not drive through flooded roads - turn around, don't drown.</p>" 3
page contact "Contact" "<p>For emergencies, call 911. For non-emergency questions during an active event, use the public information line. This demonstration site is operated by EpixDevo.</p>" 4

HOME_ID=$(wp post list --post_type=page --name=home --field=ID)
wp option update show_on_front page
wp option update page_on_front "$HOME_ID"
echo "SEED: done"
"""


def find_distribution(name):
    """The CloudFront distribution Terraform created for this environment."""
    cf = boto3.client("cloudfront")
    for page in cf.get_paginator("list_distributions").paginate():
        for d in page.get("DistributionList", {}).get("Items", []):
            if d.get("Comment") == f"{name} public site":
                return d["Id"]
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default="staging", choices=["staging", "prod"])
    ap.add_argument("--email", required=True, help="Administrator email (no mail is sent)")
    ap.add_argument("--site-url", default="https://demo.epixdevo.org")
    ap.add_argument("--region", default="us-east-1")
    args = ap.parse_args()

    name = f"storm-ready-{args.env}"
    cluster, service = f"{name}-cluster", f"{name}-cms"
    ecs = boto3.client("ecs", region_name=args.region)
    logs = boto3.client("logs", region_name=args.region)

    svc = ecs.describe_services(cluster=cluster, services=[service])["services"]
    if not svc or svc[0]["status"] != "ACTIVE":
        sys.exit(f"Service {service} not found — run `terraform apply` in envs/{args.env} first.")
    svc = svc[0]

    # Generated locally and passed only as task environment, never written to logs.
    user = "ops-" + secrets.token_hex(3)
    password = secrets.token_urlsafe(18)
    script_b64 = base64.b64encode(SEED_SCRIPT.encode()).decode()

    print(f"Starting seed task on {cluster}...")
    task = ecs.run_task(
        cluster=cluster,
        taskDefinition=svc["taskDefinition"],
        launchType="FARGATE",
        networkConfiguration=svc["networkConfiguration"],
        startedBy="seed_demo_content",
        overrides={"containerOverrides": [{
            "name": "wordpress",
            "command": ["bash", "-c", f"echo {script_b64} | base64 -d > /tmp/seed.sh && bash /tmp/seed.sh"],
            "environment": [
                {"name": "SITE_URL", "value": args.site_url},
                {"name": "SEED_USER", "value": user},
                {"name": "SEED_PASS", "value": password},
                {"name": "SEED_EMAIL", "value": args.email},
            ],
        }]},
    )
    if task.get("failures"):
        sys.exit(f"Could not start the seed task: {task['failures']}")
    task_arn = task["tasks"][0]["taskArn"]
    task_id = task_arn.rsplit("/", 1)[-1]

    print("  waiting for it to finish (usually 1–2 minutes)...")
    ecs.get_waiter("tasks_stopped").wait(cluster=cluster, tasks=[task_arn],
                                         WaiterConfig={"Delay": 10, "MaxAttempts": 60})
    stopped = ecs.describe_tasks(cluster=cluster, tasks=[task_arn])["tasks"][0]
    exit_code = stopped["containers"][0].get("exitCode")

    time.sleep(5)  # let the last log lines land
    lines = []
    try:
        events = logs.get_log_events(logGroupName=f"/ecs/{name}/cms",
                                     logStreamName=f"wordpress/wordpress/{task_id}", startFromHead=True)
        lines = [e["message"] for e in events["events"]]
    except logs.exceptions.ResourceNotFoundException:
        pass
    for line in lines:
        if line.startswith("SEED:") or exit_code != 0:
            print("  " + line)

    if exit_code != 0:
        sys.exit(f"Seed task failed (exit code {exit_code}, reason: {stopped.get('stoppedReason')}).")

    dist = find_distribution(name)
    if dist:
        boto3.client("cloudfront").create_invalidation(
            DistributionId=dist,
            InvalidationBatch={"Paths": {"Quantity": 1, "Items": ["/*"]}, "CallerReference": f"seed-{task_id}"},
        )
        print(f"  cleared the CloudFront cache ({dist})")

    if any("installed WordPress with a new administrator" in l for l in lines):
        print("\nNew administrator — save this now, it is not shown again:")
        print(f"  login:    {args.site_url}/wp-login.php")
        print(f"  username: {user}")
        print(f"  password: {password}")
    print(f"\nDone. Next: python scripts/snapshot_site.py --base-url {args.site_url} --bucket <failover_bucket>")


if __name__ == "__main__":
    main()
