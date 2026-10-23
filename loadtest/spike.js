// Storm surge load test: normal traffic, then a sudden 50x spike.
//
//   k6 run -e BASE_URL=https://dxxxx.cloudfront.net loadtest/spike.js
//
// Scenarios (pick with -e SCENARIO=...):
//   spike     (default) baseline 20 VUs → 1000 VUs in 30s → hold → recover
//   bust      same shape, but every request carries a unique query string so
//             it misses the cache and hits the origin — the "no CDN" control
//
// Make sure the runner's IP is in rate_limit_exempt_cidrs, or WAF will
// (correctly) block it as a single-IP flood.

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL;
const SCENARIO = __ENV.SCENARIO || 'spike';
const BASELINE_VUS = Number(__ENV.BASELINE_VUS || 20);
const PEAK_VUS = Number(__ENV.PEAK_VUS || BASELINE_VUS * 50);

if (!BASE_URL) {
  throw new Error('Set BASE_URL, e.g. -e BASE_URL=https://dxxxx.cloudfront.net');
}

// Pages a resident checks during an evacuation. Override with -e PATHS=/a/,/b/
const PATHS = (__ENV.PATHS ||
  '/,/evacuation-routes/,/shelter-locations/,/road-closures/,/contact/,/?s=shelter').split(',');

const edgeHit = new Rate('edge_cache_hit');
const fromFailover = new Rate('served_from_failover');
const ttfb = new Trend('time_to_first_byte', true);

export const options = {
  scenarios: {
    surge: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: BASELINE_VUS },  // normal day
        { duration: '30s', target: PEAK_VUS },     // evacuation order issued
        { duration: '3m', target: PEAK_VUS },      // sustained surge
        { duration: '1m', target: BASELINE_VUS },  // recovery
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    // The bid claim: no visitor gets an error, and pages stay fast.
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  let path = PATHS[Math.floor(Math.random() * PATHS.length)];
  if (SCENARIO === 'bust') {
    path = `/?s=bust-${__VU}-${__ITER}-${Date.now()}`;
  }

  const res = http.get(`${BASE_URL}${path}`, { tags: { page: path.split('?')[0] } });

  check(res, { 'status is 200': (r) => r.status === 200 });

  const xcache = (res.headers['X-Cache'] || '').toLowerCase();
  edgeHit.add(xcache.startsWith('hit'));
  fromFailover.add((res.body || '').includes('you are viewing a saved copy'));
  ttfb.add(res.timings.waiting);

  // A person reads the page before clicking again.
  sleep(1 + Math.random() * 2);
}
