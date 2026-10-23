# Distributed surge test (SOW 3.3)

Proves the platform sustains **~1,000,000 requests/minute** — the SCEMD
requirement in Section III.3.3 — and produces the "load testing results"
evidence Section III.5 asks for.

Six k6 generators (2 per region in us-east-1, us-east-2, us-west-2) each
drive a fixed request rate, so the fleet total is exact: 6 × 3,000 req/s =
18,000 req/s ≈ **1.08M requests/minute**. Spreading them across regions makes
traffic enter many CloudFront edge locations, as real statewide traffic does.

The fleet is throwaway: local Terraform state, no inbound access (commands go
over SSM), destroyed right after the run.

## Before the test

1. **Quotas** (AWS Console → Service Quotas, in each of the 3 regions):
   - EC2 → *Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances*:
     at least **8 vCPU** (2 × c7g.xlarge).
   - us-east-1 only: AWS Fargate → *Fargate On-Demand vCPU resource count*:
     at least **6 vCPU** (staging Emergency Mode = 12 tasks × 0.5 vCPU).
2. **WAF bypass token.** Generators share IPs across thousands of requests,
   which the per-IP rate limit would (correctly) block. Generate a token:
   ```powershell
   python -c "import secrets; print(secrets.token_hex(16))"
   ```
   Add it to `envs/staging/terraform.tfvars` as `loadtest_token = "<token>"`
   and `terraform apply` in `envs/staging`.
3. **Fresh snapshot** so failover content is current:
   `python scripts/snapshot_site.py --base-url https://demo.epixdevo.org --bucket <failover_bucket>`

## Run it

```powershell
cd loadtest\fleet
terraform init
terraform apply            # ~3 minutes; 6 instances + 3 tiny VPCs
python run.py --base-url https://demo.epixdevo.org --token <token> `
    --distribution-id (terraform -chdir=..\..\envs\staging output -raw distribution_id)
terraform destroy          # immediately after
```

`run.py` waits for the generators, starts them together, prints progress,
then writes `loadtest/results/<run-id>.json` with:

- **k6 (client side):** total requests, failed requests, error rate, worst
  p95/p99 latency across generators, edge cache hit %.
- **CloudFront (AWS's own count):** peak requests per minute, minutes at or
  above 1M, max 5xx error rate. **Quote these in the bid** — they're measured
  by AWS, not by our tool.

Total run time ≈ 15 minutes (2 min baseline, 2 min ramp, 10 min hold,
1 min ramp-down). Watch Emergency Mode switch on by itself during the ramp:
`scripts\emergency.ps1 staging status`.

## Afterwards

1. `terraform destroy` in `loadtest/fleet`.
2. Remove `loadtest_token` from `envs/staging/terraform.tfvars` and
   `terraform apply` there, so the bypass no longer exists.
3. `scripts\emergency.ps1 staging off`.

## Cost (approximate)

| Item | Estimate |
|---|---|
| 6 × c7g.xlarge for ~30 min | ~$0.50 |
| WAF requests (~13M at $0.60/M) | ~$8 |
| CloudFront requests and data | mostly within the monthly free tier (10M requests, 1 TB); a few dollars beyond it |
| Staging in Emergency Mode for the hour | ~$1 |

Roughly **$10–20 for one full run.** Run it once, for the recorded evidence.

## Notes

- AWS permits load testing your own CloudFront distribution; follow AWS's
  CloudFront load-testing guidance (distribute clients, ramp gradually). This
  is a load test, not a DDoS simulation — those require AWS's prior approval.
- The default page mix is the site's public pages. Add asset URLs or more
  pages with `PATHS` in `arrival.js` for a more realistic mix.
