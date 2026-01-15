# GymDashSync → CoachFit Integration Plan

**Date:** 2026-01-15  
**Status:** Planning Phase

---

## Executive Summary

GymDashSync is a standalone iOS app with its own Railway backend that collects HealthKit data. CoachFit is a Next.js web application designed to help coaches manage client health data. This document outlines the integration strategy to sync data from GymDashSync into CoachFit.

---

## Current State Analysis

### GymDashSync Architecture
- **iOS App:** Collects HealthKit data (workouts, weight, calories)
- **Backend:** Node.js/Express on Railway (PostgreSQL)
- **Database Schema:**
  - `workouts` - workout sessions with metrics
  - `profile_metrics` - weight, calories, steps (steps not yet implemented)
  - `clients` - client records with pairing codes
  - `warnings` - data quality warnings
- **API Endpoints:**
  - `POST /ingest/workouts` - Batch workout ingestion
  - `POST /ingest/profile` - Profile metric ingestion
  - `POST /pair` - Client pairing with code
  - Various read/UI endpoints

### CoachFit Architecture
- **Platform:** Next.js 14 with TypeScript
- **Database:** PostgreSQL via Prisma ORM
- **Existing Models:**
  - `User` - Multi-role (ADMIN, COACH, CLIENT)
  - `Entry` - Daily check-in data (weight, steps, calories, notes)
  - `Workout` - HealthKit workout records
  - `SleepRecord` - Sleep data from HealthKit
  - `PairingCode` - Coach-client pairing mechanism
  - `Cohort` - Coach groups clients into cohorts
- **Existing API Endpoints:**
  - `POST /api/pair` - Pairing with coach
  - `POST /api/ingest/workouts` - Workout ingestion
  - `POST /api/ingest/profile` - Profile metric ingestion
  - `GET /api/healthkit/workouts` - Query workouts

---

## Integration Options

### Option 1: Direct API Migration (Recommended)
**Description:** Update GymDashSync iOS app to call CoachFit APIs directly instead of the Railway backend.

**Pros:**
- Single source of truth for all data
- No data synchronization complexity
- Unified coach dashboard
- Reduced infrastructure costs (eliminate Railway backend)

**Cons:**
- Requires iOS app code changes
- API contract differences need reconciliation
- All-or-nothing migration

**Effort:** Medium (2-3 weeks)

---

### Option 2: Backend-to-Backend Sync
**Description:** Keep GymDashSync backend but add a sync service that pushes data to CoachFit periodically.

**Pros:**
- Minimal iOS app changes
- Gradual migration possible
- Fallback to Railway if CoachFit unavailable

**Cons:**
- Data synchronization complexity
- Duplicate storage
- Increased infrastructure costs
- Potential data conflicts

**Effort:** High (3-4 weeks)

---

### Option 3: Hybrid Approach
**Description:** Migrate pairing and ingestion to CoachFit but keep Railway for development/testing.

**Pros:**
- Best of both worlds
- Flexible deployment
- Good for testing

**Cons:**
- Configuration complexity
- Potential confusion about which backend to use

**Effort:** Medium (2-3 weeks)

---

## Recommended Approach: Option 1 (Direct API Migration)

### Phase 1: API Contract Alignment (Week 1)

#### 1.1 Map Data Models
| GymDashSync | CoachFit | Transformation Needed |
|-------------|----------|----------------------|
| `workouts.client_id` | `Workout.userId` | Direct mapping |
| `workouts.workout_type` | `Workout.workoutType` | Direct mapping |
| `workouts.start_time` | `Workout.startTime` | Direct mapping |
| `workouts.duration_seconds` | `Workout.durationSecs` | Direct mapping |
| `workouts.calories_active` | `Workout.caloriesActive` | Direct mapping |
| `workouts.healthkit_uuid` | Not stored | Can be added to `metadata` |
| `profile_metrics` → weight | `Entry.weightLbs` | Aggregate to daily entry |
| `profile_metrics` → calories | `Entry.calories` | Aggregate to daily entry |
| `profile_metrics` → steps | `Entry.steps` | Aggregate to daily entry |

#### 1.2 API Endpoint Mapping
| GymDashSync Endpoint | CoachFit Endpoint | Changes Needed |
|---------------------|-------------------|----------------|
| `POST /pair` | `POST /api/pair` | Request body schema differs |
| `POST /ingest/workouts` | `POST /api/ingest/workouts` | Field name mapping |
| `POST /ingest/profile` | `POST /api/ingest/profile` | Field name mapping |

#### 1.3 Request/Response Schema Alignment

**GymDashSync Pairing Request:**
```json
{
  "client_id": "uuid-v4",
  "code": "ABC123"
}
```

**CoachFit Pairing Request:**
```json
{
  "client_id": "uuid-v4",
  "code": "ABC123"
}
```
✅ **Compatible** - No changes needed

**GymDashSync Workout Ingestion:**
```json
[
  {
    "client_id": "uuid",
    "workout_type": "Running",
    "start_time": "2026-01-15T10:00:00Z",
    "end_time": "2026-01-15T10:30:00Z",
    "duration_seconds": 1800,
    "calories_active": 250,
    "distance_meters": 5000,
    "avg_heart_rate": 145,
    "source_device": "Apple Watch",
    "healthkit_uuid": "ABC-123-DEF"
  }
]
```

**CoachFit Workout Ingestion Expected:**
```json
{
  "client_id": "uuid",
  "workouts": [
    {
      "workout_type": "Running",
      "start_time": "2026-01-15T10:00:00Z",
      "end_time": "2026-01-15T10:30:00Z",
      "duration_seconds": 1800,
      "calories_active": 250,
      "distance_meters": 5000,
      "avg_heart_rate": 145,
      "max_heart_rate": 165,
      "source_device": "Apple Watch",
      "metadata": { "healthkit_uuid": "ABC-123-DEF" }
    }
  ]
}
```
⚠️ **Changes Required:**
- Wrap workout array in `{ client_id, workouts: [...] }` structure
- Move `healthkit_uuid` to `metadata` field
- Add `max_heart_rate` field (optional)

#### 1.4 Deliverables
- [ ] API contract mapping document (this section)
- [ ] Request/response transformation logic specification
- [ ] CoachFit API endpoint validation tests

---

### Phase 2: iOS App Migration (Week 2)

#### 2.1 Update API Client in iOS App
**Files to Modify:**
- `GymDashSync/BackendSyncStore.swift`
- `GymDashSync/SyncManager.swift`

**Changes:**
1. Add CoachFit base URL configuration
2. Update workout sync payload transformation
3. Update profile metric sync payload transformation
4. Update pairing flow (if needed)
5. Add error handling for new API responses

**Example Swift Code Change:**
```swift
// Before (GymDashSync format)
let workoutPayload = workouts.map { workout in
    [
        "client_id": clientId,
        "workout_type": workout.type,
        "start_time": ISO8601DateFormatter().string(from: workout.startTime),
        // ... other fields
    ]
}

// After (CoachFit format)
let workoutPayload = [
    "client_id": clientId,
    "workouts": workouts.map { workout in
        [
            "workout_type": workout.type,
            "start_time": ISO8601DateFormatter().string(from: workout.startTime),
            // ... other fields
            "metadata": [
                "healthkit_uuid": workout.uuid.uuidString
            ]
        ]
    }
]
```

#### 2.2 Configuration Management
Add environment-based backend URL switching:
```swift
enum BackendEnvironment {
    case gymDashSync // Railway backend (legacy)
    case coachFit    // CoachFit backend (new)
    
    var baseURL: String {
        switch self {
        case .gymDashSync:
            return "https://gymdashsync-production.up.railway.app"
        case .coachFit:
            return "https://coachfit.vercel.app" // Update with actual URL
        }
    }
}
```

#### 2.3 Testing Strategy
1. Test pairing flow against CoachFit staging
2. Test workout sync (1 workout, then batch)
3. Test profile metric sync
4. Verify data appears in CoachFit coach dashboard
5. Test error scenarios (network failures, invalid data, etc.)

#### 2.4 Deliverables
- [ ] Updated iOS app code
- [ ] Configuration for backend switching
- [ ] Integration test suite
- [ ] Migration guide for existing users

---

### Phase 3: Data Migration (Week 3)

#### 3.1 Migrate Existing Data (Optional)
If there's existing data in Railway backend that needs to be migrated to CoachFit:

**Script:** `backend/scripts/migrate-to-coachfit.js`
```javascript
// Pseudo-code
1. Export all workouts from Railway PostgreSQL
2. Export all profile_metrics from Railway PostgreSQL
3. Transform to CoachFit format
4. POST to CoachFit /api/ingest endpoints
5. Verify data integrity
6. Log migration results
```

#### 3.2 Dual-Write Period (Optional)
To ensure zero data loss during transition:
1. Update iOS app to write to BOTH backends temporarily
2. Monitor for 1-2 weeks
3. Verify data consistency
4. Switch to CoachFit-only

#### 3.3 Deliverables
- [ ] Data migration script (if needed)
- [ ] Migration verification report
- [ ] Rollback plan

---

### Phase 4: Backend Decommissioning (Week 4)

#### 4.1 Remove Railway Backend
1. Export final logs and metrics
2. Backup database
3. Remove Railway deployment
4. Archive codebase

#### 4.2 Update Documentation
1. Update README to reference CoachFit integration
2. Archive Railway deployment docs
3. Update Copilot instructions

#### 4.3 Deliverables
- [ ] Railway backend archived
- [ ] Documentation updated
- [ ] Cost savings report

---

## Data Model Considerations

### Missing Fields in CoachFit
The following GymDashSync fields are not currently in CoachFit schema:

1. **`workouts.healthkit_uuid`**
   - **Impact:** Deduplication relies on this
   - **Solution:** Add to `Workout.metadata` JSON field
   - **Effort:** Low (no migration needed)

2. **`workouts.source`**
   - **Impact:** Track if workout is from HealthKit vs manual
   - **Solution:** Use `Workout.sourceDevice` or add to metadata
   - **Effort:** Low

### Missing Fields in GymDashSync
The following CoachFit fields are not in GymDashSync:

1. **`Workout.maxHeartRate`**
   - **Solution:** Add to iOS HealthKit collection
   - **Effort:** Low

2. **`Entry.sleepQuality`**, **`Entry.perceivedEffort`**, **`Entry.notes`**
   - **Solution:** Out of scope for HealthKit; manual entry only
   - **Effort:** N/A

3. **`SleepRecord` model**
   - **Solution:** Add sleep data collection to iOS app
   - **Effort:** Medium (Phase 2 feature in integration plan)

---

## Steps Data Collection Gap

**Current State:**
- GymDashSync does NOT currently collect steps from HealthKit
- CoachFit expects steps data in `Entry.steps`

**Action Required:**
1. Add step count collection to iOS app HealthKit queries
2. Sync as profile metric: `{ metric: "steps", value: 10000, unit: "count" }`
3. CoachFit will aggregate to daily `Entry.steps`

**Priority:** High (required by coach)

---

## Authentication & Authorization

### Current State
- GymDashSync: Pairing code only, no user authentication
- CoachFit: NextAuth with email/password, role-based access (ADMIN, COACH, CLIENT)

### Integration Approach
1. Client pairs with coach via pairing code
2. CoachFit creates/links User record with CLIENT role
3. All subsequent API calls use `client_id` (User.id)
4. No additional authentication required from iOS app

**Security Consideration:**
- Pairing code is the trust mechanism
- Consider adding API key or JWT for future security enhancement

---

## Deployment Strategy

### Staging Environment Testing
1. Deploy CoachFit to staging environment
2. Configure iOS app to use staging URL
3. Test full pairing and sync flow
4. Verify coach dashboard displays data correctly

### Production Rollout
1. **Week 1:** Deploy API changes to CoachFit production
2. **Week 2:** Release iOS app update (v2.0) with CoachFit integration
3. **Week 3:** Monitor for errors, provide user support
4. **Week 4:** Decommission Railway backend (if no issues)

### Rollback Plan
- Keep Railway backend running for 30 days post-migration
- iOS app can be configured to switch back if needed
- Database backups at each stage

---

## Success Criteria

- [ ] iOS app successfully pairs with CoachFit coaches
- [ ] Workout data syncs to CoachFit and appears in coach dashboard
- [ ] Profile metrics (weight, steps, calories) sync daily
- [ ] No data loss during migration
- [ ] Railway backend costs eliminated
- [ ] Coach reports satisfaction with unified dashboard

---

## Risks & Mitigation

| Risk | Impact | Likelihood | Mitigation |
|------|--------|-----------|------------|
| API contract mismatch | High | Medium | Thorough testing in staging |
| Data loss during migration | High | Low | Dual-write period, backups |
| CoachFit downtime | Medium | Low | Keep Railway as fallback |
| iOS app bugs post-release | Medium | Medium | Phased rollout, monitoring |
| User confusion | Low | Medium | Clear communication, support docs |

---

## Next Steps

1. ✅ Document current state and integration options (this document)
2. ⬜ Review with stakeholders and get approval
3. ⬜ Set up CoachFit staging environment
4. ⬜ Begin Phase 1: API contract alignment
5. ⬜ Test pairing flow end-to-end
6. ⬜ Update iOS app to call CoachFit APIs
7. ⬜ Migrate existing data (if applicable)
8. ⬜ Decommission Railway backend

---

## Open Questions

1. **CoachFit Production URL:** What is the production URL for API calls?
2. **Existing Data:** Do we need to migrate historical data from Railway?
3. **Steps Collection:** Should we implement steps before or after migration?
4. **Sleep Data:** Is sleep data collection required for MVP integration?
5. **Multi-Coach Support:** Can a client be paired with multiple coaches?

---

_Last Updated: 2026-01-15_
