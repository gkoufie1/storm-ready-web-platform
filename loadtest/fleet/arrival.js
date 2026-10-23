// Fixed-rate surge test run on each fleet generator (started by run.py).
//
// Unlike spike.js (virtual users who pause to read), this drives an exact
// request rate, so the fleet total is a precise number: e.g. 6 generators
// x 3,000 req/s = 18,000 req/s = 1.08M requests/minute.
//
// Shape: 2% of target for 2 minutes (a normal day, long enough for the surge
// alarm to see the jump), ramp to 100%, hold, ramp down.

import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL;
const RATE = Number(__ENV.RATE);          // requests/second from THIS generator
const RAMP = __ENV.RAMP || '2m';
const HOLD = __ENV.HOLD || '10m';
const TOKEN = __ENV.TOKEN || '';
const PATHS = (__ENV.PATHS ||
  '/,/evacuation-routes/,/shelter-locations/,/road-closures/,/contact/').split(',');

if (!BASE_URL || !RATE) {
  throw new Error('BASE_URL and RATE are required');
}

const edgeHit = new Rate('edge_cache_hit');

export const options = {
  discardResponseBodies: true,   // headers are enough; saves generator CPU
  scenarios: {
    surge: {
      executor: 'ramping-arrival-rate',
      timeUnit: '1s',
      startRate: Math.max(1, Math.round(RATE * 0.02)),
      preAllocatedVUs: Math.max(50, Math.round(RATE * 0.1)),
      maxVUs: Math.max(200, Math.round(RATE * 0.5)),
      stages: [
        { duration: '2m', target: Math.max(1, Math.round(RATE * 0.02)) },
        { duration: RAMP, target: RATE },
        { duration: HOLD, target: RATE },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const params = { headers: { 'X-Loadtest-Token': TOKEN } };

export default function () {
  const path = PATHS[Math.floor(Math.random() * PATHS.length)];
  const res = http.get(`${BASE_URL}${path}`, params);
  check(res, { 'status is 200': (r) => r.status === 200 });
  edgeHit.add((res.headers['X-Cache'] || '').toLowerCase().startsWith('hit'));
}

// run.py collects this file from every generator and aggregates it.
export function handleSummary(data) {
  return { 'summary.json': JSON.stringify(data) };
}
