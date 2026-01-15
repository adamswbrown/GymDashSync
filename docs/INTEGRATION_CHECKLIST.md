# Integration Checklist

Quick reference for GymDashSync → CoachFit integration tasks.

## Phase 1: API Contract Alignment ✅

- [ ] Map GymDashSync data models to CoachFit schema
- [ ] Document API endpoint mappings
- [ ] Identify request/response schema differences
- [ ] Test CoachFit endpoints with Postman/curl
- [ ] Update CoachFit OpenAPI spec (if exists)

## Phase 2: CoachFit Backend Updates

### Database Changes
- [ ] Add `healthkit_uuid` field to `Workout.metadata` handling
- [ ] Verify `Entry` daily aggregation logic exists
- [ ] Test deduplication logic for workouts

### API Endpoint Validation
- [ ] Test `POST /api/pair` with GymDashSync request format
- [ ] Test `POST /api/ingest/workouts` with transformed payload
- [ ] Test `POST /api/ingest/profile` with profile metrics
- [ ] Verify error responses are informative
- [ ] Add request validation with Zod

### Coach Dashboard
- [ ] Verify workout data displays correctly
- [ ] Verify daily Entry data shows weight/steps/calories
- [ ] Test date filtering and sorting
- [ ] Add "Synced from HealthKit" badge/indicator

## Phase 3: iOS App Updates

### Configuration
- [x] Add CoachFit base URL to app config
- [x] Add environment switcher (dev/staging/prod)
- [ ] Update Info.plist with new backend permissions

### API Client Updates
- [x] Update `BackendSyncStore.swift` to use CoachFit format
- [x] Transform workout payload (wrap in `workouts` array)
- [ ] Move `healthkit_uuid` to `metadata` field
- [ ] Update pairing request format (if needed)
- [x] Update profile metric sync format
- [ ] Add proper error handling for new API responses

### HealthKit Data Collection
- [x] **HIGH PRIORITY:** Add step count collection
- [x] Wire step ingestion endpoint in client
 - [ ] Verify weight collection is working
 - [ ] Verify active calories collection is working
 - [ ] Consider adding max heart rate to workouts
- [ ] (Future) Add sleep data collection
- [x] Wire sleep ingestion endpoint in client
- [x] Add step permission request
- [x] Add sleep permission request
- [x] Add HealthKit step query + daily aggregation
- [x] Add HealthKit sleep query + daily aggregation

### Background Sync & Persistence
- [x] Implement SyncQueue with Core Data persistence
- [x] Implement exponential backoff retry logic (2s base, max 5 retries)
- [x] Implement BackgroundSyncTask for periodic processing
- [x] Create Core Data model for sync operations
- [x] Add pending operation queue management
- [ ] Integrate SyncQueue into BackendSyncStore for failed syncs
- [ ] Integrate BackgroundSyncTask into app lifecycle

### Testing
- [ ] Test pairing flow against CoachFit staging
- [ ] Test single workout sync
- [ ] Test batch workout sync (10+ workouts)
- [ ] Test profile metric sync
- [ ] Test error scenarios (network failure, invalid code, etc.)
- [ ] Test with real HealthKit data on device

## Phase 4: Data Migration (If Needed)

- [ ] Export existing data from Railway PostgreSQL
- [ ] Write transformation script
- [ ] Test migration on staging environment
- [ ] Validate data integrity post-migration
- [ ] Run production migration
- [ ] Verify all clients can see their historical data

## Phase 5: Deployment

### Staging
- [ ] Deploy CoachFit changes to staging
- [ ] Build iOS app with staging config
- [ ] Test full end-to-end flow
- [ ] Get approval from stakeholders

### Production
- [ ] Deploy CoachFit API changes to production
- [ ] Release iOS app update to TestFlight
- [ ] Beta test with 5-10 users
- [ ] Monitor logs and error rates
- [ ] Release to App Store

### Post-Launch
- [ ] Monitor sync success rates
- [ ] Address any reported issues
- [ ] Keep Railway backend running for 30 days (fallback)
- [ ] After 30 days: decommission Railway

## Phase 6: Cleanup

- [ ] Archive Railway backend code
- [ ] Update GymDashSync README
- [ ] Update AGENT_INSTRUCTIONS.md
- [ ] Remove Railway-specific code from iOS app
- [ ] Document lessons learned

---

## Critical Path Items

These MUST be completed before integration:

1. [ ] Steps data collection in iOS app
2. [x] API payload transformation (workouts array wrapper)
3. [ ] CoachFit staging environment setup
4. [ ] End-to-end pairing test
5. [ ] Workout data visible in coach dashboard

---

## Quick Commands

### Test CoachFit API
```bash
# Test pairing
curl -X POST https://coachfit-staging.vercel.app/api/pair \
  -H "Content-Type: application/json" \
  -d '{"client_id":"uuid","code":"ABC123"}'

# Test workout ingestion
curl -X POST https://coachfit-staging.vercel.app/api/ingest/workouts \
  -H "Content-Type: application/json" \
  -d @test-workout-payload.json
```

### iOS Development
```bash
# Build for simulator
cd GymDashSync
xcodebuild -scheme GymDashSync -destination 'platform=iOS Simulator,name=iPhone 15'

# Run tests
xcodebuild test -scheme GymDashSync -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Database Queries
```sql
-- Check recent workouts in CoachFit
SELECT * FROM "Workout" 
WHERE "userId" = 'client-uuid' 
ORDER BY "startTime" DESC 
LIMIT 10;

-- Check daily entries
SELECT * FROM "Entry"
WHERE "userId" = 'client-uuid'
ORDER BY date DESC
LIMIT 7;
```

---

_Last Updated: 2026-01-15_
