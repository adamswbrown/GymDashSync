# GymDashSync Backend

Lightweight backend ingestion service for receiving HealthKit data from iOS clients. Uses SQLite for local development with a PostgreSQL-compatible schema for easy migration later.

## Identity Model: Pairing Codes

The backend uses a **pairing code** system for multi-user identity:

- **No Authentication**: No passwords, no OAuth, no Apple Sign-In
- **Pairing Codes**: Short codes (6-8 characters) that map to `client_id` (UUID)
- **Client Ownership**: All data is tagged with `client_id` - ownership is determined solely by this identifier
- **One-Time Exchange**: Pairing codes are exchanged for `client_id` once, then the iOS app persists the `client_id` locally

**Why Pairing Codes?**

This is a developer-first system. Pairing codes provide:
- Simple identity bootstrap without authentication complexity
- Easy testing and development
- Clear path to migrate to Apple Sign-In later (same data schema, same `client_id` model)
- No cloud dependencies during development

The pairing logic is isolated from the data ingestion pipeline, making it easy to replace with proper authentication later.

## Overview

This backend service:
- Receives HealthKit data from iOS clients via HTTP POST
- Stores data in SQLite (file-based, persisted on disk)
- Provides **full web UI for coaches** to manage clients and inspect data
- Validates all ingested data with comprehensive error checking
- Deduplicates workouts automatically
- Tracks data quality warnings
- Uses portable SQL that migrates cleanly to PostgreSQL

**Note:** SQLite is used for development. Schema is intentionally portable for PostgreSQL migration later.

### Coach Web UI (Primary Interface)

**All coach operations are available via web browser - no CLI required for normal operation.**

Access the web UI at: `http://localhost:3000/ui`

**Features:**
- ✅ Create clients with pairing codes (via web form)
- ✅ View all clients with summary statistics
- ✅ Inspect individual client data (workouts, profile metrics)
- ✅ View data quality warnings
- ✅ See deduplication status
- ✅ No manual SQL or CLI steps needed

**No authentication yet** - this is a development system.

## Installation

### Prerequisites
- Node.js 14+ (or use nvm to manage versions)
- npm (comes with Node.js)

### Install Dependencies

```bash
cd backend
npm install
```

This will install:
- `express` - Web framework
- `better-sqlite3` - SQLite database driver

## Running the Server

### Start the Server

```bash
npm start
```

The server will:
- Initialize the database schema (creates tables and indexes if missing)
- Start listening on port 3000
- Log startup information to console

### Server Endpoints

Once running, the server provides:

- **Health Check**: `GET http://localhost:3000/health`
- **Ingest Workouts**: `POST http://localhost:3000/ingest/workouts`
- **Ingest Profile**: `POST http://localhost:3000/ingest/profile`
- **Read Workouts**: `GET http://localhost:3000/workouts`
- **Read Profile**: `GET http://localhost:3000/profile`
- **Query Workouts**: `POST http://localhost:3000/workouts/query` (for iOS client fetchObjects)
- **Query Profile**: `POST http://localhost:3000/profile-metrics/query` (for iOS client fetchObjects)

## Database

### Location
The SQLite database file is created at: `backend/database.sqlite`

### Schema

**Table: workouts**
- Stores workout data (runs, walks, cycles, strength training, etc.)
- Indexed on `client_id` and `start_time`

**Table: profile_metrics**
- Stores body metrics (height, weight, body fat percentage)
- Indexed on `client_id` and `metric`

**Table: clients**
- Maps pairing codes to client_id (UUID)
- Used for pairing code exchange
- Indexed on `pairing_code` for fast lookups

See `db/init.js` for full schema definition.

### Creating Clients and Pairing Codes

**Via Web UI (Recommended):**
1. Open `http://localhost:3000/ui` in your browser
2. Click "Create New Client"
3. Optionally enter a label (e.g., "John Doe")
4. Click "Create Client"
5. The pairing code will be displayed - share this with the client

**Via API:**
```bash
curl -X POST http://localhost:3000/clients \
  -H "Content-Type: application/json" \
  -d '{"label": "John Doe"}'
```

**Via CLI (Legacy - use web UI instead):**
```bash
npm run create-pairing [CODE]
```

Each client gets:
- A new UUID as `client_id`
- A unique 6-character pairing code (auto-generated)
- Optional label for easy identification
- Timestamp of creation

## Web UI Usage

### Creating a Client

1. Navigate to `http://localhost:3000/ui`
2. Click "Create New Client"
3. Enter an optional label (e.g., "John Doe")
4. Click "Create Client"
5. **Copy the pairing code** - this is what the client enters in the iOS app
6. Share the pairing code with the client

### Viewing Client Data

1. From the clients list, click "View" on any client
2. See:
   - Recent workouts with all metrics
   - Profile metrics (height, weight, body fat)
   - Data quality warnings
   - Summary statistics

### Understanding Warnings

Warnings appear when:
- Duration doesn't match time delta (±10% tolerance)
- Unknown workout types (mapped to "other")
- Unusual values (e.g., heart rate > 300)
- Duplicate workouts (skipped automatically)

All warnings are logged and visible in the UI.

## API Examples

### Pair Device

```bash
curl -X POST http://localhost:3000/pair \
  -H "Content-Type: application/json" \
  -d '{
    "pairing_code": "ABC123"
  }'
```

**Response (success):**
```json
{
  "client_id": "550e8400-e29b-41d4-a716-446655440000"
}
```

**Response (failure):**
```json
{
  "error": "invalid pairing code"
}
```

**Note:** Pairing code lookup is case-insensitive. The iOS app will store the returned `client_id` and use it for all subsequent sync operations.

### Ingest Workouts

**Important:** All workout payloads MUST include `client_id`. The backend will reject payloads without it.

```bash
curl -X POST http://localhost:3000/ingest/workouts \
  -H "Content-Type: application/json" \
  -d '[
    {
      "client_id": "550e8400-e29b-41d4-a716-446655440000",
      "source": "apple_health",
      "workout_type": "run",
      "start_time": "2024-01-15T10:00:00Z",
      "end_time": "2024-01-15T10:30:00Z",
      "duration_seconds": 1800,
      "calories_active": 250.5,
      "distance_meters": 5000.0,
      "avg_heart_rate": 150.0,
      "source_device": "apple_watch"
    }
  ]'
```

**Response:**
```json
{
  "success": true,
  "count_received": 1,
  "count_inserted": 1,
  "duplicates_skipped": 0,
  "warnings_count": 0,
  "errors_count": 0
}
```

### Ingest Profile Metrics

**Important:** All profile metric payloads MUST include `client_id`. The backend will reject payloads without it.

```bash
curl -X POST http://localhost:3000/ingest/profile \
  -H "Content-Type: application/json" \
  -d '[
    {
      "client_id": "550e8400-e29b-41d4-a716-446655440000",
      "metric": "weight",
      "value": 75.5,
      "unit": "kg",
      "measured_at": "2024-01-15T08:00:00Z",
      "source": "apple_health"
    },
    {
      "client_id": "550e8400-e29b-41d4-a716-446655440000",
      "metric": "height",
      "value": 175.0,
      "unit": "cm",
      "measured_at": "2024-01-15T08:00:00Z",
      "source": "apple_health"
    }
  ]'
```

**Response:**
```json
{
  "success": true,
  "count_received": 2,
  "count_inserted": 2,
  "warnings_count": 0,
  "errors_count": 0
}
```

### Read All Workouts

```bash
curl http://localhost:3000/workouts
```

**Response:**
```json
[
  {
    "id": 1,
    "client_id": "550e8400-e29b-41d4-a716-446655440000",
    "source": "apple_health",
    "workout_type": "run",
    "start_time": "2024-01-15T10:00:00Z",
    "end_time": "2024-01-15T10:30:00Z",
    "duration_seconds": 1800,
    "calories_active": 250.5,
    "distance_meters": 5000.0,
    "avg_heart_rate": 150.0,
    "source_device": "apple_watch",
    "created_at": "2024-01-15T12:00:00Z"
  }
]
```

### Read All Profile Metrics

```bash
curl http://localhost:3000/profile
```

**Response:**
```json
[
  {
    "id": 1,
    "client_id": "550e8400-e29b-41d4-a716-446655440000",
    "metric": "weight",
    "value": 75.5,
    "unit": "kg",
    "measured_at": "2024-01-15T08:00:00Z",
    "source": "apple_health",
    "created_at": "2024-01-15T12:00:00Z"
  },
  {
    "id": 2,
    "client_id": "550e8400-e29b-41d4-a716-446655440000",
    "metric": "height",
    "value": 175.0,
    "unit": "cm",
    "measured_at": "2024-01-15T08:00:00Z",
    "source": "apple_health",
    "created_at": "2024-01-15T12:00:00Z"
  }
]
```

### Query Workouts by UUIDs

```bash
curl -X POST http://localhost:3000/workouts/query \
  -H "Content-Type: application/json" \
  -d '{
    "uuids": ["550e8400-e29b-41d4-a716-446655440000"]
  }'
```

**Response:**
```json
[]
```

**Note:** Currently returns empty array (graceful degradation). The iOS client will treat all records as new. To enable proper UUID matching, add a `healthkit_uuid` column to the workouts table.

### Query Profile Metrics by UUIDs

```bash
curl -X POST http://localhost:3000/profile-metrics/query \
  -H "Content-Type: application/json" \
  -d '{
    "uuids": ["550e8400-e29b-41d4-a716-446655440000"]
  }'
```

**Response:**
```json
[]
```

**Note:** Currently returns empty array (graceful degradation). The iOS client will treat all records as new. To enable proper UUID matching, add a `healthkit_uuid` column to the profile_metrics table.

## Project Structure

```
backend/
├── server.js              # Express app entry point
├── database.sqlite        # SQLite database file (created on first run)
├── db/
│   ├── init.js           # Database schema initialization
│   ├── connection.js     # SQLite connection setup
│   └── queries.js        # All SQL queries (prepared statements)
├── routes/
│   ├── ingest.js         # POST endpoints for data ingestion
│   └── read.js           # GET endpoints for data retrieval
├── package.json          # Dependencies and scripts
└── README.md            # This file
```

## Data Validation & Deduplication

### Validation Rules

**Workouts:**
- `client_id` must exist in clients table
- `start_time` must be before `end_time`
- `duration_seconds` must roughly match time delta (±10% tolerance)
- All timestamps must be valid ISO8601
- Unknown `workout_type` mapped to "other" with warning
- Numeric fields validated for reasonable ranges

**Profile Metrics:**
- `client_id` must exist in clients table
- `value` must be a number
- `measured_at` must be valid ISO8601
- Metric type validated (height, weight, body_fat)
- Value ranges checked (e.g., height 50-300cm)

**Ownership:**
- Every batch must contain only ONE `client_id`
- `client_id` is authoritative - ownership never inferred
- Data never leaks across clients

### Deduplication

Workouts are considered duplicates if:
- Same `client_id`
- `start_time` within ±120 seconds
- `duration_seconds` within ±10% tolerance

Duplicate workouts are:
- Skipped (not inserted)
- Logged as warnings
- Counted in ingest response (`duplicates_skipped`)

### Ingest Response Format

All ingest endpoints return detailed reports:

```json
{
  "success": true,
  "count_received": 5,
  "count_inserted": 4,
  "duplicates_skipped": 1,
  "warnings_count": 2,
  "errors_count": 0,
  "errors": []
}
```

## Development Notes

### SQL Portability

All SQL is written to be compatible with both SQLite and PostgreSQL:
- Uses standard SQL types (TEXT, INTEGER, REAL)
- No SQLite-specific features (no JSON blobs, no triggers)
- Indexes use standard CREATE INDEX syntax
- Prepared statements work in both databases

### Transactions

Data ingestion uses transactions to ensure atomicity:
- Multiple records are inserted in a single transaction
- If any record fails, the entire batch is rolled back

### Error Handling

- Invalid JSON returns 400 with error message
- Database errors return 500 with error message
- All errors are logged to console

### Logging

The server logs:
- Startup information
- Each HTTP request (method + path)
- Each ingestion operation (client_id + count)
- Errors with full stack traces

## Future Migration to PostgreSQL

When ready to migrate to PostgreSQL:

1. **Connection**: Replace `better-sqlite3` with `pg` (node-postgres)
2. **Schema**: Convert `AUTOINCREMENT` to `SERIAL` or `GENERATED ALWAYS AS IDENTITY`
3. **Queries**: Most SQL should work as-is (test thoroughly)
4. **Connection Pooling**: Add connection pooling for production

The schema is intentionally designed to make this migration straightforward.

## Assumptions Validated

The system enforces and validates these assumptions:

**A1. Ownership**
- ✅ Every record belongs to exactly one `client_id`
- ✅ Ownership is never inferred
- ✅ `client_id` is authoritative
- ✅ Multi-client isolation enforced

**A2. Pairing**
- ✅ Pairing codes are human-enterable (6 chars, no ambiguous chars)
- ✅ Pairing happens once per device
- ✅ `client_id` persists locally on iOS

**A3. Data Contract**
- ✅ Required fields enforced
- ✅ Optional fields tolerated
- ✅ Invalid data visible (warnings, not silently dropped)

**A4. Deduplication**
- ✅ Duplicate workouts skipped deterministically
- ✅ Legitimate workouts not dropped
- ✅ Dedup observable in logs + UI

**A5. Multi-client Isolation**
- ✅ Data never leaks across clients in UI or API
- ✅ All queries filtered by `client_id`

## Limitations (By Design)

This backend intentionally does NOT include:
- ❌ Authentication/authorization (dev system)
- ❌ Migration framework
- ❌ Cloud dependencies
- ❌ Scale optimizations
- ❌ Pagination (shows last 50-100 records)

These can be added later as needed.

