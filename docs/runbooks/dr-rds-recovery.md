# Runbook: DR — RDS recovery from automated snapshot

**Type**: Recovery procedure + regularly-scheduled drill.
**RTO target**: 30 min (mvp), 15 min (prod).
**RPO target**: 24h (mvp, single automated daily backup) / 5 min (prod, PITR is enabled).
**Blast radius**: Zero for the drill script (restores into a sandbox instance, doesn't touch prod).

## Purpose

Validate that:
1. RDS automated snapshots are being taken at the configured retention (7 days on mvp, 30 days on prod).
2. A snapshot can be restored into a new instance without manual intervention.
3. The restored instance contains recognizable data (rows in `accounts`, `workspaces`, `inference_configs`).
4. **RTO measurement** — how long between "snapshot exists" and "app-ready DB endpoint" is captured for capacity planning.

## When to run

- **Quarterly drill**: run `scripts/dr-drill.sh` from `~/llmsafespaces-cdk`, no args.
- **After changing RDS instance class or engine version**: rerun to confirm the new class can accept restores (some larger instance classes need more time; gp3 vs io1 changes IO characteristics).
- **Before a major migration**: use the drill as a snapshot-time-in-hand check.
- **When actually recovering from data loss**: skip the drill script; use the "Actual recovery" section below.

## Prerequisites

- `AWS_PROFILE=mikekao-prod` (or export before running).
- `kubectl` context = `llmsafespaces` (used for the psql verify pod). If not set:
  ```bash
  aws eks update-kubeconfig --profile mikekao-prod --region us-west-2 --name llmsafespaces
  ```
- `python3` for parsing the master-secret JSON (macOS/linux both have it).

## Running the drill

```bash
cd ~/llmsafespaces-cdk
./scripts/dr-drill.sh
```

Expected output (annotated):

```
[2026-07-02T14:00:00-07:00] Locating production RDS instance...
[2026-07-02T14:00:01-07:00] Production instance: llmsafespaces-data-postgres...
[2026-07-02T14:00:01-07:00] Finding latest automated snapshot...
[2026-07-02T14:00:02-07:00] Snapshot: rds:llmsafespaces-data-postgres...-2026-07-02-11-08 (created ...)
[2026-07-02T14:00:02-07:00] Starting restore into llmsafespaces-dr-drill-20260702140002...
[2026-07-02T14:00:02-07:00] Waiting for the restore to complete (up to 1800 seconds)....................................
[2026-07-02T14:06:34-07:00] Restore complete. RTO (snapshot start → available): 392s
[2026-07-02T14:06:34-07:00] Verifying row counts on key tables...
[2026-07-02T14:06:34-07:00] Spawning ephemeral verification pod...
users|0
workspaces|0
organizations|0
provider_credentials|1
[2026-07-02T14:07:00-07:00] Verify OK: total rows across sample tables = 1
[2026-07-02T14:07:00-07:00] Deleting llmsafespaces-dr-drill-20260702140002...
[2026-07-02T14:07:03-07:00] Deletion request submitted. Instance will be fully removed within 5-10 min.
[2026-07-02T14:07:03-07:00]
[2026-07-02T14:07:03-07:00] === DR drill report ===
[2026-07-02T14:07:03-07:00]   Prod instance:      llmsafespaces-data-postgres...
[2026-07-02T14:07:03-07:00]   Source snapshot:    rds:...-2026-07-02-11-08 (age: 3h)
[2026-07-02T14:07:03-07:00]   Drill instance:     llmsafespaces-dr-drill-20260702140002
[2026-07-02T14:07:03-07:00]   RTO measured:       392s
[2026-07-02T14:07:03-07:00]   Verify status:      ok
[2026-07-02T14:07:03-07:00]   Teardown status:    requested
```

**Log the RTO number** in the tables below after each drill.

### Cost

Each drill:
- ~10 min of a db.t4g.micro (~$0.02/hr × 0.2h = < $0.01)
- Snapshot storage is free (billing quota shares with existing snapshots)
- No cross-AZ or cross-region data transfer

Total: negligible per drill (< $0.10 including the transient EKS pod).

## RTO history

| Date | Snapshot age | RTO (seconds) | Verify status | Notes |
|------|--------------|---------------|---------------|-------|
| 2026-07-02 | ~7h | **392** | ok | First recorded drill on mvp tier (db.t4g.micro, gp3, single-AZ). Restore start → available: 6m 32s. Verify: schema present, 1 row in `provider_credentials`. Well under the 30-min mvp target. |

## Failure modes seen in prior drills

None yet (this is the first-established DR runbook).

Future entries here should record: what went wrong, what changed to fix it, and whether the fix was CDK, ops-prod, script, or process.

## Actual recovery (not a drill — data loss has happened)

**Do not use `dr-drill.sh` for real recovery.** The drill script always restores to a `-drill-<timestamp>` instance and tears it down. For a real recovery:

### Option A: Restore in-place (RDS PITR available on prod tier)

Only available on the `prod` tier where PITR is enabled. Restores the same DB endpoint but rewinds to a point in time within the backup window.

```bash
# 1. Determine the target time (max 5 minutes before the incident,
#    or `latest_restorable_time` for max-recent).
PROD_INSTANCE=<production-instance-id>
LATEST_RESTORABLE=$(aws rds describe-db-instances --profile mikekao-prod --region us-west-2 \
  --db-instance-identifier "$PROD_INSTANCE" \
  --query 'DBInstances[0].LatestRestorableTime' --output text)
echo "Latest restorable: $LATEST_RESTORABLE"

# 2. Rename the corrupt instance out of the way (or delete it — no
#    going back if you do this, and the rename is safer).
aws rds modify-db-instance --profile mikekao-prod --region us-west-2 \
  --db-instance-identifier "$PROD_INSTANCE" \
  --new-db-instance-identifier "${PROD_INSTANCE}-corrupt-$(date +%Y%m%d)" \
  --apply-immediately

# 3. Restore. This CREATES A NEW instance; the DNS on the ALB will
#    take ~5 min to catch up.
aws rds restore-db-instance-to-point-in-time --profile mikekao-prod --region us-west-2 \
  --source-db-instance-identifier "${PROD_INSTANCE}-corrupt-$(date +%Y%m%d)" \
  --target-db-instance-identifier "$PROD_INSTANCE" \
  --restore-time "$LATEST_RESTORABLE" \
  --db-subnet-group-name <subnet-group> \
  --vpc-security-group-ids <sg-id> \
  --db-instance-class db.t4g.micro \
  --no-multi-az \
  --publicly-accessible false

# 4. Wait for it to be `available`, then verify the app reconnects.
aws rds wait db-instance-available --profile mikekao-prod --region us-west-2 \
  --db-instance-identifier "$PROD_INSTANCE"

# 5. Restart the API pods so they refresh connection pool.
kubectl -n llmsafespaces rollout restart deploy/llmsafespaces-api

# 6. Once app is healthy, delete the -corrupt instance (or snapshot it
#    for forensics first).
aws rds delete-db-instance --profile mikekao-prod --region us-west-2 \
  --db-instance-identifier "${PROD_INSTANCE}-corrupt-$(date +%Y%m%d)" \
  --final-db-snapshot-identifier "${PROD_INSTANCE}-corrupt-forensics-$(date +%Y%m%d)"
```

### Option B: Restore from automated snapshot (any tier)

Snapshots go back `backupRetention` days (7 mvp / 30 prod). Snapshots are taken during the daily maintenance window; PITR is not available so you can't rewind to a specific minute — only to the moment of the snapshot.

```bash
# 1. Find the target snapshot. `list-snapshots-sorted-by-time` isn't
#    a thing; describe + jq client-side.
PROD_INSTANCE=<production-instance-id>
aws rds describe-db-snapshots --profile mikekao-prod --region us-west-2 \
  --db-instance-identifier "$PROD_INSTANCE" \
  --snapshot-type automated \
  --query 'DBSnapshots[*].{Id:DBSnapshotIdentifier,Time:SnapshotCreateTime,Size:AllocatedStorage}' \
  --output table

# Choose the latest good one, or the most recent one from BEFORE the
# corruption event.
SNAPSHOT_ID=<pick from the above>

# 2. Same as Option A steps 2-6 but replace `restore-db-instance-to-point-in-time`
#    with:
aws rds restore-db-instance-from-db-snapshot --profile mikekao-prod --region us-west-2 \
  --db-instance-identifier "$PROD_INSTANCE" \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --db-subnet-group-name <subnet-group> \
  --vpc-security-group-ids <sg-id> \
  --db-instance-class db.t4g.micro \
  --no-multi-az \
  --publicly-accessible false \
  --deletion-protection false
```

### After either recovery

- The RESTORED instance's master password is unchanged (RDS restores retain the master password from the snapshot). No secret rotation needed unless the operator suspects credential compromise.
- If your app's ORM cached the pre-recovery IP: pods restart automatically on DNS-alias change (endpoint is a stable DNS name, not IP). Force a restart if you see connection errors > 30s:
  ```bash
  kubectl -n llmsafespaces rollout restart deploy/llmsafespaces-api deploy/llmsafespaces-controller
  ```
- **File an incident report** under `docs/incidents/YYYY-MM-DD-<slug>.md` capturing: what triggered the recovery, RTO/RPO achieved, gaps between plan and reality.

## Related

- CDK RDS config: `~/llmsafespaces-cdk/lib/data-stack.ts:108-131`
- CDK MonitoringStack alarms for RDS: `~/llmsafespaces-cdk/lib/monitoring-stack.ts`
- Related issue: [lenaxia/llmsafespaces-aws-cdk#16](https://github.com/lenaxia/llmsafespaces-aws-cdk/issues/16)
