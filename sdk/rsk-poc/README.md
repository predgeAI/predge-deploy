# Deadline helper (Rootstock testnet PoC)

Every deadline of a PoC job, in UTC and in your local time zone, plus "closing soon" events at 48 h and 24 h (and "passed").
Read-only: no keys, no transactions. Uses chain time, the clock the contracts use.

| Job state | Deadline | Who acts |
|---|---|---|
| Open | `submit`: package must be submitted before `expiredAt` | contractor |
| Submitted, no objection | `objection`: `submittedAt + objectionPeriod` (10 days); after it anyone can call `releaseOnSilence` | client |
| Submitted, objection filed | `reviewerDecision`: `submittedAt + evaluationWindow` (24 days) | reviewer |
| Submitted | `refundFallback`: after `submittedAt + evaluationWindow` anyone can call `claimRefund` | anyone |

```js
import { readJobDeadlines, closingSoon } from "./sdk/rsk-poc/deadlines.mjs";
const d = await readJobDeadlines({ job, evaluator, jobId: 1, timeZone: "America/Bogota" });
closingSoon(d, { jobId: 1 }); // [{ type: "closing_soon", deadline: "objection", window: "48h", utc, local, hoursLeft, ... }]
```

Watcher (one JSON line per event, each event sent once, optional webhook):

```bash
node scripts/rsk-poc/deadline-watch.mjs --jobs 1,2 --tz America/Bogota --webhook https://example.com/hook --loop 900
```

Tests: `node --test sdk/rsk-poc/`
