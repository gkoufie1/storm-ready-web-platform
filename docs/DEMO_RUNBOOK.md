# Demo Runbook — "The Evacuation Order"

A ~3-minute recorded demo for the bid. Everything runs against **staging**.
Total AWS cost for one session: a few dollars. Destroy afterwards.

## Before recording (≈30 min)

1. `terraform apply` in `envs/staging` (≈15 min).
2. Install WordPress at `<site_url>/wp-admin/install.php`. Create a few
   pages that look like an agency site: *Evacuation Routes*, *Shelter
   Locations*, *Road Closures*, *Contact*.
3. Snapshot the site:
   `python scripts/snapshot_site.py --base-url <site_url> --bucket <failover_bucket>`
4. Run `python scripts/smoke_test.py ...` — all PASS.
5. Open in browser tabs, side by side:
   - CloudWatch dashboard (or metrics): CloudFront *Requests*, *5xxErrorRate*,
     *CacheHitRate*; ECS *RunningTaskCount*; ALB *TargetResponseTime*
   - The site homepage
   - A terminal
6. Load-test runner: put its public IP in `rate_limit_exempt_cidrs`. For more
   than ~500 VUs, run k6 from an EC2 instance or k6 Cloud — a laptop on home
   internet becomes the bottleneck before AWS does.

## Recording script

| Time | Show | Say |
|---|---|---|
| 0:00 | Architecture diagram | "Agency site on AWS. Built to stay up when the whole state shows up at once." |
| 0:20 | Terminal: `scripts/emergency.sh staging status` | "Normal day: one task, database paused, short cache times." |
| 0:35 | Start `k6 run -e BASE_URL=<site_url> loadtest/spike.js` | "Evacuation order goes out. Traffic goes 50× in 30 seconds." |
| 0:50 | CloudWatch: surge alarm fires → Emergency Mode turns on by itself; task count rises | "The platform noticed and switched itself into Emergency Mode." |
| 1:30 | Browser: site is still fast | "Residents still get the page in milliseconds — almost all from the edge." |
| 1:50 | Terminal: `scripts/origin_outage.sh staging start` | "Now the worst case: we take the CMS down completely." |
| 2:10 | Browser: open `<site_url>/?s=outage-123` (a new search term forces a fresh origin fetch; other query strings are ignored by the cache) — page loads with the "saved copy" banner | "CloudFront fails over to the static copy. No error page, ever." |
| 2:30 | k6 summary: `http_req_failed` < 1%, p95 latency | "Final numbers: X requests, Y% errors, p95 Z ms." |
| 2:45 | `scripts/emergency.sh staging off` | "Storm passes. One command returns to normal cost." |

## Numbers to capture for the proposal

From the k6 summary and CloudWatch:

- Peak requests/second at the edge
- `http_req_failed` rate (target: < 1%) and p95 / p99 latency
- `edge_cache_hit` rate during the surge
- Time from alarm to Emergency Mode applied (Lambda log timestamps)
- Time to failover after the CMS was stopped
- Cost of the surge hour (Cost Explorer, next day)

Also run the `bust` scenario (`-e SCENARIO=bust`) once at modest load to
show what happens *without* edge caching — the contrast makes the point.

## After recording

```bash
scripts/origin_outage.sh staging end
scripts/emergency.sh staging off
cd envs/staging && terraform destroy
```
