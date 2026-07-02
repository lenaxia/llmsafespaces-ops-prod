# RdsCpuHigh

**Severity**: warning
**Fires when**: RDS Postgres CPU >80% for 15 min.
**Impact**: API request latency increases. If sustained, saturates the connection pool and API returns 500s.

## First 60 seconds

```bash
# 1. Confirm the alarm is real (not a spike that already recovered)
aws cloudwatch get-metric-statistics --profile mikekao-prod --region us-west-2 \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=<db-id> \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Average

# 2. Look at active queries
kubectl -n llmsafespaces exec deploy/llmsafespaces-api -- \
  psql $DATABASE_URL -c "
    SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state
    FROM pg_stat_activity
    WHERE (now() - pg_stat_activity.query_start) > interval '10 seconds'
    ORDER BY duration DESC LIMIT 10;
  "

# 3. Check connection count
kubectl -n llmsafespaces exec deploy/llmsafespaces-api -- \
  psql $DATABASE_URL -c "SELECT count(*) FROM pg_stat_activity;"
```

## Common causes

### 1. Long-running query
`pg_stat_activity` shows one query running for minutes with `state = 'active'`.

**Fix**:
```bash
# Kill the offending query (get pid from step 2 above)
kubectl -n llmsafespaces exec deploy/llmsafespaces-api -- \
  psql $DATABASE_URL -c "SELECT pg_cancel_backend($PID);"
# If cancel doesn't work, escalate:
kubectl -n llmsafespaces exec deploy/llmsafespaces-api -- \
  psql $DATABASE_URL -c "SELECT pg_terminate_backend($PID);"
```

Follow-up: look at what query it was, whether it needs an index, whether the API code should be rate-limited.

### 2. Missing index causing table scans
Repeated slow queries on the same table. `EXPLAIN ANALYZE` the query.

**Fix**: Add index. Coordinate with a maintenance window since `CREATE INDEX` on a busy table locks writes.

### 3. Application traffic spike
Legitimate high load. Check ALB requests/second.

**Fix**: If sustained, scale RDS up:
```bash
# Bump to db.t4g.small (2 vCPU) or db.m6g.large (2 vCPU with dedicated resources)
aws rds modify-db-instance --profile mikekao-prod --region us-west-2 \
  --db-instance-identifier <db-id> \
  --db-instance-class db.m6g.large \
  --apply-immediately
```

Costs ~$30/mo → ~$120/mo for db.m6g.large. Rebuild takes ~5min with brief downtime.

## Escalation

If CPU stays >80% for >30 min despite no obvious cause:
- Check if RDS Performance Insights shows top wait events
- Enable enhanced monitoring if not already
- Consider engaging AWS Support (Business tier for real-time)
