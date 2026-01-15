# Project Pause Checkpoint – GymDashSync

## Current State (Confirmed Working)
- Backend deployed on Railway: https://gymdashsync-production.up.railway.app
- PostgreSQL fully migrated and in use (no SQLite runtime)
- Backend health check confirms DB connectivity
- iOS V1 app updated to:
  - Point to Railway backend by default
  - Display backend hostname
  - Show sync state clearly (syncing, last sync time)
  - Show counts for workouts and profile metrics
  - Display the most recent workout synced
- Pairing flow remains unchanged and functional
- Manual sync works end-to-end against Railway

## Key Architectural Decisions (Do Not Revisit Lightly)
- PostgreSQL-only backend (fail fast if DATABASE_URL missing)
- No ORM; raw SQL via pg.Pool
- Idempotent schema initialization on startup
- Manual sync only (no background sync yet)
- No authentication changes
- No coach-specific data model yet
- No log querying in Railway; logs are runtime stdout only

## Coach Data Requirements (Confirmed)
The coach’s required dataset is:
- Weight (lbs)
- Steps
- Calories (active energy)

Notes:
- Weight is likely already collected via HealthKit
- Calories (active energy) likely already collected; must be verified
- Steps are NOT currently collected and represent the only confirmed ingestion gap
- All three belong in `profile_metrics` (no schema changes required)

## Known Gaps / Next Work When Resuming
1. Verify which HealthKit profile metrics are currently ingested:
   - Confirm presence of weight and calories in Railway DB
   - Identify whether steps are missing
2. If steps are missing:
   - Add HealthKit step count ingestion
   - Ingest as a profile metric (metric="steps", unit="count")
   - No backend changes required
3. Improve backend logging for sync visibility:
   - Emit structured JSON logs for sync events
   - Use Railway runtime logs for visibility (no log querying yet)
4. Decide on next phase direction:
   - Coach-facing summaries/export
   - Background sync (optional)
   - Authentication (out of scope so far)

## Explicit Non-Goals (As of This Pause)
- No background sync
- No authentication
- No new backend endpoints
- No data model redesign
- No coach UI or dashboards
- No log aggregation service
- No migration tooling beyond startup schema init

## Re-entry Goal
When resuming, first objective is to **confirm the system captures the coach’s three required metrics reliably**, then decide whether to:
- Enhance visibility (UI/export), or
- Expand ingestion (steps), or
- Move toward coach-facing workflows