# Load Test Results — October 23, 2026

Evidence for SCEMD IFB 5400030123, SOW Section III.3.3 (≈1,000,000
requests/minute without degradation) and III.3.4 (scaling within 45 minutes).

## Setup

| Item | Value |
|---|---|
| Target | `https://demo.epixdevo.org` (staging environment, CloudFront distribution `EY0ETLG1DJ8PZ`) |
| Generators | 6 × c7g.xlarge running k6 0.54.0 — 2 each in us-east-1, us-east-2, us-west-2 |
| Load shape | Fixed arrival rate: 2% of target for 2 min, ramp 2 min, **hold 18,000 req/s (1.08M/min) for 10 min**, ramp down 1 min |
| Page mix | `/`, `/evacuation-routes/`, `/shelter-locations/`, `/road-closures/`, `/contact/` |
| Run ID | `run-20261023T173420Z` (started 17:34:20 UTC) |
| Tooling | [`loadtest/fleet/`](../loadtest/fleet/README.md) |

## Results — CloudFront (measured by AWS, CloudWatch `AWS/CloudFront`)

| Minute (UTC) | Requests |
|---|---|
| 17:34 | 12,334 |
| 17:35 | 21,600 |
| 17:36 | 107,982 |
| 17:37 | 587,262 |
| 17:38 | **1,025,790** |
| 17:39 | **1,075,777** |
| 17:40 | **1,076,927** |
| 17:41 | **1,079,988** |
| 17:42 | **1,080,017** |
| 17:43 | **1,079,989** |
| 17:44 | **1,080,008** |
| 17:45 | **1,068,667** |
| 17:46 | **1,079,995** |
| 17:47 | **1,079,998** |
| 17:48 | 903,716 (ramp-down begins) |
| 17:49 | 99,372 |

- **Peak:** 1,080,017 requests/minute
- **Sustained:** above 1,000,000 requests/minute for **10 consecutive minutes** (17:38–17:47)
- **5xx error rate (max, any minute):** 0.0%
- **Ramp absorbed without errors:** the test ramped from 2% of target to the
  full 1.08M/min over 2 minutes (a shape chosen by the test, not a platform
  limit), and the platform served it with zero failed requests.
- **Emergency Mode / origin scaling timing (SOW 3.4):** _to be confirmed from
  the Emergency Mode state parameter and ECS scaling events — pending._
- **Cross-check:** CloudFront counted 12,459,444 requests (17:30–17:49) vs.
  k6's 12,459,415 — within 29 requests (manual spot checks during the run).

## Results — k6 (client side)

| Generator | Requests | Failed | p95 ms | p99 ms |
|---|---|---|---|---|
| i-03302c804e1b49d66 | 2,079,126 | 0 | 11.5 | 26.5 |
| i-03d1128ea7757df05 | 2,077,931 | 0 | 4.6 | 9.1 |
| i-0633fa5a9c766f774 | 2,072,643 | 0 | 4.3 | 9.0 |
| i-080aaa0235ca78915 | 2,072,745 | 0 | 4.4 | 9.0 |
| i-09473885f21c1e8ab | 2,077,893 | 0 | 4.6 | 9.3 |
| i-0e2720c53a94b8cdf | 2,079,077 | 0 | 11.5 | 26.5 |
| **Total** | **12,459,415** | **0** | **≤ 11.5** | **≤ 26.5** |

## Caveats (stated plainly)

- Tested against the **staging** environment with a small set of public
  pages, so nearly all requests were served from the CloudFront edge cache.
  That is the designed behavior during an activation, but a real event has a
  wider URL mix and some uncached traffic (e.g. search).
- Generators ran in three US AWS regions, not from residential networks.
