"""Crawl the public site and publish a static snapshot to the failover bucket.

CloudFront falls back to this snapshot whenever the CMS origin returns
5xx or is unreachable. Each page is stored under a key ending in "/"
(site/about/), matching the distribution's origin_path "/site", so
/about/ resolves to it directly with no edge function.

Every snapshot page gets a small banner so visitors know they're seeing a
saved copy. Run after publishing content, and on a schedule:

    python scripts/snapshot_site.py --base-url https://dxxxx.cloudfront.net \
        --bucket <failover_bucket output>
"""

import argparse
import re
import sys
import time
from collections import deque
from datetime import datetime, timezone
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen

import boto3

SKIP_PREFIXES = ("/wp-admin", "/wp-login.php", "/wp-json", "/xmlrpc.php", "/wp-cron.php")
CSS_URL = re.compile(r"url\(\s*['\"]?([^'\")]+)['\"]?\s*\)")
BODY_TAG = re.compile(r"(<body[^>]*>)", re.IGNORECASE)

BANNER = (
    '<div role="status" style="background:#7a1f1f;color:#fff;padding:10px 16px;'
    'font:600 15px/1.4 system-ui,sans-serif;text-align:center">'
    "High traffic: you are viewing a saved copy of this site from {stamp}. "
    "Some features are temporarily unavailable.</div>"
)


class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if not value:
                continue
            if name in ("href", "src"):
                self.links.append(value)
            elif name == "srcset":
                self.links.extend(part.strip().split(" ")[0] for part in value.split(","))


def s3_key(prefix, path):
    """'/'→'site/', '/about/'→'site/about/', '/a.css'→'site/a.css'."""
    return f"{prefix}/{path.lstrip('/')}" if path != "/" else f"{prefix}/"


def crawl(base_url, max_pages):
    host = urlsplit(base_url).netloc
    queue = deque(["/"])
    seen = {"/"}
    pages = {}

    while queue and len(pages) < max_pages:
        path = queue.popleft()
        url = urljoin(base_url, path)
        try:
            with urlopen(Request(url, headers={"User-Agent": "storm-ready-snapshot/1.0"}), timeout=20) as resp:
                body = resp.read()
                content_type = resp.headers.get("Content-Type", "application/octet-stream")
        except (HTTPError, URLError) as exc:
            print(f"  skip {path}: {exc}", file=sys.stderr)
            continue

        pages[path] = (body, content_type)

        if "text/html" in content_type:
            parser = LinkParser()
            parser.feed(body.decode("utf-8", errors="replace"))
            candidates = parser.links
        elif "text/css" in content_type:
            candidates = CSS_URL.findall(body.decode("utf-8", errors="replace"))
        else:
            candidates = []

        for link in candidates:
            parts = urlsplit(urljoin(url, link))
            if parts.netloc != host or parts.scheme not in ("http", "https"):
                continue
            # S3 ignores query strings, so ?ver=6.6 variants collapse to one key.
            target = parts.path or "/"
            if target.startswith(SKIP_PREFIXES) or target in seen:
                continue
            seen.add(target)
            queue.append(target)

    return pages


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--prefix", default="site")
    ap.add_argument("--max-pages", type=int, default=500)
    args = ap.parse_args()

    started = time.time()
    stamp = datetime.now(timezone.utc).strftime("%B %d, %Y %H:%M UTC")
    pages = crawl(args.base_url.rstrip("/") + "/", args.max_pages)
    if "/" not in pages:
        sys.exit("Homepage could not be fetched — refusing to publish an empty snapshot.")

    s3 = boto3.client("s3")
    for path, (body, content_type) in pages.items():
        if "text/html" in content_type:
            html = body.decode("utf-8", errors="replace")
            body = BODY_TAG.sub(lambda m: m.group(1) + BANNER.format(stamp=stamp), html, count=1).encode("utf-8")
        s3.put_object(
            Bucket=args.bucket,
            Key=s3_key(args.prefix, path),
            Body=body,
            ContentType=content_type,
            CacheControl="max-age=300",
        )

    html_count = sum(1 for _, ct in pages.values() if "text/html" in ct)
    print(f"Snapshot published: {html_count} pages, {len(pages) - html_count} assets "
          f"to s3://{args.bucket}/{args.prefix}/ in {time.time() - started:.1f}s")


if __name__ == "__main__":
    main()
