# GymDashSync Database Analysis Report
## SQLite vs PostgreSQL Migration Assessment for V2

**Date:** January 8, 2026  
**Database:** SQLite (better-sqlite3)  
**Purpose:** Evaluate suitability for background event-driven sync

---

## Executive Summary

**Current State:** The SQLite database is small (0.18 MB, 141 workouts) and structurally simple, but has a **critical configuration issue**: WAL mode is not enabled, which will cause lock contention under concurrent background syncs.

**Key Findings:**
1. ❌ **WAL mode disabled** - Single-writer lock will bottleneck concurrent syncs
2. ⚠️ **Inefficient write pattern** - Individual inserts in loop (not batched)
3. ✅ **Schema is PostgreSQL-portable** - Minimal migration effort required
4. ✅ **Small scale currently** - SQLite sufficient for development/small production
5. ⚠️ **Single-writer limitation** - Hard SQLite constraint will be problematic at scale

**Recommendation:** Enable WAL mode immediately for V2, but plan PostgreSQL migration within 3-6 months if expecting >10 concurrent clients or >100 workouts/day total write volume.

**Migration Urgency:** **MEDIUM** - Not blocking for V2 launch, but should be prioritized once usage patterns are known.

---

## 1. Current Database Footprint

### Physical Characteristics

| Metric | Value |
|--------|-------|
| **File Path** | `/Users/adambrown/Developer/GymDashSync/backend/database.sqlite` |
| **File Size** | 0.18 MB (188,416 bytes) |
| **Page Size** | 4,096 bytes (default) |
| **Page Count** | 46 pages |
| **Free Pages** | 11 (24% fragmentation) |
| **Last Modified** | 2026-01-08 08:22:41 UTC |

### Configuration Status

| Setting | Current Value | Status |
|---------|--------------|--------|
| **Journal Mode** | `delete` | ❌ **CRITICAL: WAL not enabled** |
| **Synchronous** | `2` (FULL) | Conservative (safe but slower) |
| **Foreign Keys** | ON | ✅ Enabled |
| **WAL File** | None | Not in WAL mode |

### Data Volume (Current)

| Table | Rows | Est. Size | Growth Pattern |
|-------|------|-----------|----------------|
| `workouts` | 141 | ~38 KB | High frequency append |
| `profile_metrics` | 10 | ~2 KB | Low frequency append |
| `warnings` | 2 | ~0.3 KB | Low frequency append |
| `clients` | 1 | ~0.1 KB | Very low frequency |

**Total:** ~40 KB of actual data (excluding indexes, metadata, free space)

### Recent Activity (Last 7 Days)

- **Workouts:** 141 inserted (~20/day)
- **Profile Metrics:** 10 inserted (~1.4/day)
- **Clients:** 1 (pairing-time only)

---

## 2. Structural Complexity Assessment

### Schema Overview

**Total Tables:** 4  
**Total Indexes:** 12  
**Complexity Level:** **LOW** ✅

#### Table Details

**1. `workouts` (Primary data table)**
- **Columns:** 13
- **Primary Key:** `id` (INTEGER AUTOINCREMENT)
- **Indexes:** 4
  - `idx_workouts_client_id` (single column)
  - `idx_workouts_start_time` (single column)
  - `idx_workouts_client_start` (composite: client_id, start_time)
  - `idx_workouts_uuid` (healthkit_uuid)
- **Unique Constraints:** None (deduplication in code)
- **Foreign Keys:** None (client_id validated in application)
- **Estimated Row Size:** ~280 bytes
- **Write Pattern:** Append-only (inserts only, no updates)

**2. `profile_metrics`**
- **Columns:** 9
- **Primary Key:** `id` (INTEGER AUTOINCREMENT)
- **Indexes:** 4
  - `idx_profile_metrics_client_id` (single column)
  - `idx_profile_metrics_metric` (single column)
  - `idx_profile_metrics_client_measured` (composite: client_id, measured_at)
  - `idx_profile_metrics_uuid` (healthkit_uuid)
- **Estimated Row Size:** ~226 bytes
- **Write Pattern:** Append-only

**3. `clients`**
- **Columns:** 5
- **Primary Key:** `id` (INTEGER AUTOINCREMENT)
- **Indexes:** 2 (redundant - UNIQUE constraints already create indexes)
  - `idx_clients_pairing_code` (UNIQUE)
  - `idx_clients_client_id` (UNIQUE)
- **Write Pattern:** Low-frequency (pairing-time only)

**4. `warnings`**
- **Columns:** 7
- **Primary Key:** `id` (INTEGER AUTOINCREMENT)
- **Indexes:** 2
  - `idx_warnings_client_id`
  - `idx_warnings_created_at`
- **Estimated Row Size:** ~166 bytes
- **Write Pattern:** Append-only (validation/debug data)

### Index Redundancy Notes

⚠️ **Minor Optimization Opportunity:**
- Composite indexes (`idx_workouts_client_start`, `idx_profile_metrics_client_measured`) overlap with single-column indexes
- Safe but not optimal - PostgreSQL would benefit from removing redundant single-column indexes

### Foreign Key Constraints

- **None in schema** - All foreign key validation happens in application code
- This is actually a **plus for migration** - no FK constraint migration needed
- Multi-client isolation enforced via `client_id` filtering in queries

---

## 3. Write Patterns Analysis

### Current Ingestion Pattern (CRITICAL ISSUE)

**Location:** `backend/routes/ingest.js` (lines 96-139)

**Pattern:** Individual inserts in a loop - **NOT batched**

```javascript
// Current pattern (inefficient for concurrent writes)
for (const workout of workouts) {
    const validation = validateWorkout(workout, clientId);      // In-memory
    const isDup = isDuplicateWorkout(workout);                  // DB query #1
    if (isDup) {
        createWarning(...);                                      // DB write #1
        continue;
    }
    const result = insertWorkout(workout);                      // DB write #2
    if (validation.warnings.length > 0) {
        createWarning(...);                                      // DB write #3
    }
}
```

**Problems:**
1. Each record = 2-4 database operations (query + 1-2 writes)
2. No transaction wrapping the entire batch
3. Each `insertWorkout()` call is a separate implicit transaction
4. Lock contention will spike with concurrent requests

**Note:** `insertWorkouts()` batch function exists but is **not used** by the ingestion handler.

### Write Classification

| Table | Write Pattern | Frequency (V2) | Concurrency Risk |
|-------|--------------|----------------|------------------|
| `workouts` | Append-only (insert) | **HIGH** | **CRITICAL** - Main bottleneck |
| `profile_metrics` | Append-only (insert) | Medium | Medium - Less frequent |
| `warnings` | Append-only (insert) | Low | Low - Debug data |
| `clients` | Append-only (insert) | Very Low | Negligible |

### Deletion Pattern

- **Workouts/Profile Metrics:** Deletions are **UUID-based bulk deletes** via `DELETE /api/v1/workouts` endpoint
- **Clients:** Cascade deletes (transaction-wrapped, safe)
- **Frequency:** Low (user-initiated cleanup)

---

## 4. Concurrency & Locking Risk

### SQLite Concurrency Model

**Current Configuration:**
- Journal Mode: `delete` (default, not WAL)
- Connection: Single instance (better-sqlite3)
- Writers: **1 at a time** (hard SQLite limit)
- Readers: Blocked during writes (in `delete` mode)

### Lock Contention Analysis

**Current State (Manual Sync):**
- ✅ Low contention - sequential user-triggered syncs
- ✅ Single writer sufficient

**V2 State (Background Event-Driven):**
- ❌ **HIGH RISK** - Multiple devices syncing simultaneously
- ❌ Each sync = multiple write operations (per workout)
- ❌ Better-sqlite3 is **synchronous** - no async write queue
- ❌ `delete` journal mode = **exclusive write lock** blocks all reads

### WAL Mode Impact

**If WAL Enabled:**
- ✅ Multiple concurrent readers (no blocking)
- ✅ Writer still exclusive (1 at a time)
- ✅ Faster checkpointing (async)
- ⚠️ Still single-writer bottleneck

**If WAL NOT Enabled (Current):**
- ❌ Single writer blocks ALL readers
- ❌ Every write = full database lock
- ❌ Background sync will queue up and timeout

### Transaction Patterns

**Current Pattern:**
- Individual inserts = individual transactions (implicit)
- No batch transaction wrapping
- Deduplication queries run separately

**Risk Level:**
- **With WAL:** MEDIUM (single writer, but concurrent reads OK)
- **Without WAL (current):** **HIGH** (full lock during every write)

### Recommendation

**IMMEDIATE ACTION REQUIRED:**
```javascript
// Add to backend/db/connection.js:
db.pragma('journal_mode = WAL');
```

This is a **zero-risk change** and will dramatically improve concurrent performance.

---

## 5. Migration Portability Assessment

### SQL Compatibility

**✅ HIGHLY PORTABLE** - Schema designed with PostgreSQL in mind

#### Data Type Mapping

| SQLite Type | PostgreSQL Equivalent | Status |
|-------------|----------------------|--------|
| `TEXT` | `TEXT` or `VARCHAR` | ✅ Direct mapping |
| `INTEGER` | `INTEGER` or `BIGINT` | ✅ Direct mapping |
| `REAL` | `DOUBLE PRECISION` | ✅ Direct mapping |
| No `BLOB` | N/A | ✅ No binary data |

#### Syntax Compatibility Issues

**Minor Issues (Easily Fixed):**

1. **AUTOINCREMENT → SERIAL/GENERATED**
   ```sql
   -- SQLite (current)
   id INTEGER PRIMARY KEY AUTOINCREMENT
   
   -- PostgreSQL (migration)
   id SERIAL PRIMARY KEY
   -- OR (modern)
   id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY
   ```

2. **Timestamp Storage**
   - Current: TEXT (ISO8601 strings) - ✅ Portable
   - Migration: Can stay as TEXT, or convert to TIMESTAMP
   - Recommendation: Keep as TEXT for compatibility during migration

#### Index Compatibility

- ✅ All indexes use standard SQL syntax
- ✅ `CREATE INDEX IF NOT EXISTS` works in both
- ✅ Composite indexes are standard

#### Constraint Compatibility

- ✅ UNIQUE constraints work identically
- ✅ No CHECK constraints to migrate
- ✅ No foreign key constraints in schema (all in code)

### Migration Effort Estimate

**Effort Level: LOW-MEDIUM**

**Required Changes:**
1. Replace `better-sqlite3` with `pg` (node-postgres) - 1-2 hours
2. Update connection handling - 1 hour
3. Replace `AUTOINCREMENT` with `SERIAL` - 30 minutes
4. Update `PRAGMA` statements (remove SQLite-specific) - 30 minutes
5. Test migration script - 2-4 hours
6. Data export/import - 1 hour (data is small)

**Total Estimate:** 6-9 hours of focused work

### Migration Risk

**Risk Level: LOW**

- No complex queries to rewrite
- No stored procedures
- No triggers
- No SQLite-specific features used
- Small data volume (easy to test/rollback)

---

## 6. Growth Projections

### Current Scale

- **Clients:** 1
- **Workouts:** 141 (~141 per client)
- **Profile Metrics:** 10 (~10 per client)
- **Activity Rate:** ~20 workouts/day

### Projection Scenarios

#### Scenario A: Small Scale (Development/Small Production)
- **Clients:** 10 active
- **Workouts:** 5 per week per client
- **Metrics:** 2 per month per client

**Projections:**
- Workouts/year: 2,600 (50/week × 52 weeks)
- Workouts/year size: ~0.56 MB
- 5-year total: ~2.79 MB
- **Verdict:** ✅ SQLite comfortable (even at 10x this)

#### Scenario B: Medium Scale (Production)
- **Clients:** 50 active
- **Workouts:** 10 per week per client
- **Metrics:** 1 per week per client

**Projections:**
- Workouts/year: 26,000 (500/week × 52 weeks)
- Workouts/year size: ~5.58 MB
- 5-year total: ~27.89 MB
- **Verdict:** ✅ SQLite still comfortable (size-wise)

#### Scenario C: Large Scale (Growth Phase)
- **Clients:** 200 active
- **Workouts:** 15 per week per client
- **Metrics:** 1 per week per client

**Projections:**
- Workouts/year: 156,000 (3,000/week × 52 weeks)
- Workouts/year size: ~33.5 MB
- 5-year total: ~167.5 MB
- **Verdict:** ⚠️ SQLite size OK, but **concurrency becomes bottleneck**

### SQLite Capacity Limits

- **Max DB Size:** 281 TB (theoretical), 140 TB (practical)
- **Max Rows:** 2^64 (no practical limit)
- **Concurrent Writers:** **1 (hard limit)** ⚠️
- **Concurrent Readers:** Many (with WAL), blocked (without WAL)

### Bottleneck Analysis

**Size is NOT the constraint:**
- Even at 100K workouts/year for 10 years = ~56 MB
- SQLite can handle TB-scale databases

**Concurrency IS the constraint:**
- Single writer limit becomes problematic at:
  - >10 concurrent syncs (background event-driven)
  - >100 workouts/day total write volume
  - Peak usage spikes (morning syncs)

**When SQLite Becomes Uncomfortable:**
- **Size:** Never (for this use case)
- **Concurrency:** When background sync frequency > single-writer capacity

---

## 7. Hosting Options Comparison

### Option 1: SQLite (Current) - Hosted with Backend

**Pros:**
- ✅ Zero additional infrastructure cost
- ✅ Zero latency (local file system)
- ✅ Simple backups (file copy)
- ✅ Works perfectly for <10 concurrent clients
- ✅ No connection pooling needed

**Cons:**
- ❌ Single-writer limit (hard SQLite constraint)
- ❌ File-based (backup/HA complexity)
- ❌ No horizontal scaling
- ❌ WAL mode required for V2 (must enable)

**Cost:** $0 (part of backend server)

**Recommendation:** ✅ **Good for V2 launch** if WAL enabled + <10 concurrent clients

---

### Option 2: Serverless Postgres (Neon / Supabase)

**Neon:**
- **Free Tier:** 0.5 GB storage, 1 branch, shared CPU
- **Paid Tier:** $19/month (1 GB, 0.5 vCPU) → $99/month (10 GB, 2 vCPU)
- **Pros:**
  - ✅ Auto-scaling compute
  - ✅ Branching (dev/staging databases)
  - ✅ Point-in-time recovery
  - ✅ Serverless (scales to zero)
- **Cons:**
  - ⚠️ Cold starts (serverless)
  - ⚠️ Network latency (vs local SQLite)

**Supabase:**
- **Free Tier:** 500 MB storage, 2 GB bandwidth
- **Paid Tier:** $25/month (8 GB, dedicated)
- **Pros:**
  - ✅ Full Postgres + auth + storage
  - ✅ Real-time subscriptions (if needed)
  - ✅ Good developer experience
- **Cons:**
  - ⚠️ More features than needed
  - ⚠️ Vendor lock-in risk

**Cost:** $0-25/month (free tier sufficient for <10 clients)

**Recommendation:** ✅ **Good option if migration planned** - Neon preferred for simplicity

---

### Option 3: Managed Postgres (Azure / AWS RDS / Railway)

**Azure Database for PostgreSQL:**
- **Basic Tier:** $25-50/month (single server, 2-4 GB)
- **Pros:**
  - ✅ Enterprise-grade HA/redundancy
  - ✅ Automated backups
  - ✅ VNet integration
- **Cons:**
  - ❌ Overkill for small scale
  - ❌ Higher cost

**AWS RDS PostgreSQL:**
- **t3.micro:** ~$15/month (1 vCPU, 1 GB RAM, 20 GB storage)
- **Pros:**
  - ✅ Mature, reliable
  - ✅ Multi-AZ available
- **Cons:**
  - ❌ More complex setup
  - ❌ Higher minimum cost

**Railway:**
- **Postgres Addon:** $5/month (1 GB, shared), $20/month (10 GB, dedicated)
- **Pros:**
  - ✅ Simple, developer-friendly
  - ✅ Good for small scale
  - ✅ Integrated with Railway deployments
- **Cons:**
  - ⚠️ Smaller provider (less enterprise features)

**Cost:** $5-50/month depending on provider/tier

**Recommendation:** ⚠️ **Consider if you need enterprise features** - Railway $5 tier is reasonable

---

## 8. Recommendations

### Immediate Actions (Before V2 Launch)

1. **✅ ENABLE WAL MODE** (Critical)
   ```javascript
   // backend/db/connection.js
   db.pragma('journal_mode = WAL');
   ```
   - Zero-risk change
   - Enables concurrent reads
   - Required for background sync

2. **⚠️ OPTIMIZE INGESTION** (Recommended)
   - Use batch `insertWorkouts()` instead of loop
   - Wrap entire batch in single transaction
   - Reduces lock contention by 10-100x

3. **✅ MONITOR CONCURRENCY** (Required)
   - Log write queue depth
   - Track sync latency
   - Alert on lock timeouts

### Short-Term (V2 Launch - 3 months)

**Decision:** **Stay with SQLite + WAL mode**

**Rationale:**
- Small scale (likely <10 concurrent clients initially)
- Size is not a constraint
- WAL mode sufficient for concurrent reads
- Single writer acceptable if ingestion optimized

**Conditions to Monitor:**
- Concurrent sync count > 5 regularly
- Write queue depth > 10 requests
- Sync latency > 5 seconds

### Medium-Term (3-6 months post-V2)

**Decision:** **Migrate to PostgreSQL if:**
- >10 concurrent clients active
- >100 workouts/day total write volume
- Lock contention observed (timeouts, queue depth)

**Recommended Target:** **Neon Serverless Postgres**
- Free tier sufficient initially
- Scales up as needed
- Simple migration path
- Good developer experience

**Alternative:** Railway Postgres ($5/month) if you prefer simplicity over serverless features

### Long-Term (6+ months)

**Decision:** **Managed Postgres (Azure/AWS)** if:
- >50 active clients
- Need HA/multi-region
- Enterprise compliance requirements
- Team familiar with cloud provider

---

## 9. Migration Roadmap (If Needed)

### Phase 1: Preparation (1-2 days)

1. Enable WAL mode (required for zero-downtime migration)
2. Optimize ingestion to use batch inserts
3. Add migration readiness checks (monitoring)

### Phase 2: Schema Migration (1 day)

1. Create PostgreSQL schema (convert AUTOINCREMENT → SERIAL)
2. Set up Neon/Railway database
3. Test schema compatibility

### Phase 3: Dual-Write (Optional, 1 week)

1. Write to both SQLite and PostgreSQL
2. Verify data consistency
3. Run queries against both (shadow reads)

### Phase 4: Cutover (1 day)

1. Export SQLite data
2. Import to PostgreSQL
3. Update connection strings
4. Monitor for issues

**Total Effort:** 3-5 days (with testing)

---

## 10. Final Verdict

### SQLite Suitability

**Current State:** ⚠️ **SUITABLE WITH FIXES**

**After WAL Enable:** ✅ **SUITABLE FOR V2 LAUNCH**

**Long-Term:** ⚠️ **MIGRATE IN 3-6 MONTHS** (if growth occurs)

### Migration Urgency

**Urgency Level: MEDIUM**

- Not blocking for V2 launch
- WAL mode fix is critical
- Plan migration for Q2-Q3 2026
- Monitor usage patterns post-launch

### Clear Recommendation

**For V2 Launch:**
1. ✅ Enable WAL mode immediately
2. ✅ Optimize ingestion (batch inserts)
3. ✅ Stay with SQLite
4. ✅ Monitor concurrency metrics

**Post-Launch (3-6 months):**
1. ⚠️ Evaluate actual usage patterns
2. ⚠️ Migrate to Neon Postgres if >10 concurrent clients
3. ⚠️ Consider Railway if simpler infrastructure preferred

**Cost-Benefit:**
- **SQLite (V2):** $0, sufficient for small scale, requires WAL fix
- **Neon Postgres (Growth):** $0-19/month, better concurrency, minimal migration effort
- **Managed Postgres (Scale):** $25-50/month, enterprise features, overkill for now

---

## Appendix: Code Changes Required

### Critical Fix: Enable WAL Mode

**File:** `backend/db/connection.js`

```javascript
const db = new Database(dbPath);

// Enable WAL mode for concurrent reads
db.pragma('journal_mode = WAL');

// Optional: Optimize for performance
db.pragma('synchronous = NORMAL');  // Faster than FULL, still safe with WAL
db.pragma('cache_size = -64000');   // 64 MB cache

// Existing code
db.pragma('foreign_keys = ON');
```

### Recommended: Optimize Ingestion

**File:** `backend/routes/ingest.js`

Replace individual inserts with batch transaction:

```javascript
// Instead of loop with individual inserts
// Use batch transaction for all valid records
const validWorkouts = workouts.filter(w => {
    const validation = validateWorkout(w, clientId);
    if (!validation.isValid) {
        errors++;
        return false;
    }
    return !isDuplicateWorkout(w);
});

// Single transaction for all inserts
if (validWorkouts.length > 0) {
    const { insertWorkouts } = require('../db/queries');
    inserted = insertWorkouts(validWorkouts);
}
```

This reduces lock contention by batching writes into a single transaction.

---

**Report Generated:** January 8, 2026  
**Next Review:** Post-V2 launch (3 months) or when >10 concurrent clients
