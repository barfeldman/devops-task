# sample-nodejs

The Node app on its own. It is a small Express server on port 8080: a couple of
string routes, Prometheus metrics, and readiness and liveness endpoints. Set
`PORT` to change the port. `/classified` checks an `x-api-token` header against the
`API_TOKEN` env var and returns 401 when it does not match.

Routes: `/my-app`, `/about`, `/ready`, `/live`, `/classified`, `/metrics`.

## Run it

```bash
npm ci
npm test        # smoke test, see test/smoke.js
node app.js
curl localhost:8080/my-app
```

Needs Node 22. How this gets containerised, scanned and deployed is in the repo
README one level up.
