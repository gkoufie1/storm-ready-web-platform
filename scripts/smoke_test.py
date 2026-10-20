"""Post-deploy smoke test: checks the live platform, not just that apply exited 0.

    python scripts/smoke_test.py --site-url https://dxxxx.cloudfront.net \
        --alb-dns <alb_dns_name output>
"""

import argparse
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def fetch(url):
    req = Request(url, headers={"User-Agent": "storm-ready-smoke/1.0"})
    try:
        with urlopen(req, timeout=30) as resp:
            return resp.status, resp.headers
    except HTTPError as exc:
        return exc.code, exc.headers
    except URLError as exc:
        return None, str(exc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site-url", required=True)
    ap.add_argument("--alb-dns", required=True)
    args = ap.parse_args()
    site = args.site_url.rstrip("/")

    status, headers = fetch(site + "/")
    checks = [
        ("Homepage via CloudFront returns 200", status == 200),
        ("HSTS header present", status is not None and "strict-transport-security" in {k.lower() for k in headers.keys()}),
        ("Served through CloudFront", status is not None and headers.get("Via", "").lower().find("cloudfront") >= 0),
    ]

    status, _ = fetch(f"http://{args.alb_dns}/")
    checks.append(("Direct ALB access is refused (no origin secret)", status in (403, None)))

    status, _ = fetch(site + "/xmlrpc.php")
    checks.append(("WAF blocks /xmlrpc.php", status == 403))

    failed = False
    for name, ok in checks:
        print(f"[{'PASS' if ok else 'FAIL'}] {name}")
        failed |= not ok
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
