# Railway Deployment Guide

This guide covers deploying the GymDashSync backend to Railway.

## Prerequisites

- Railway account (sign up at https://railway.app)
- GitHub repository linked to Railway
- Node.js 18+ (Railway auto-detects from `package.json`)

## Railway Setup

### 1. Create New Project

1. Log into Railway dashboard
2. Click "New Project"
3. Select "Deploy from GitHub repo"
4. Choose the GymDashSync repository

### 2. Add PostgreSQL Service

1. In your Railway project, click "+ New"
2. Select "Database" → "Add PostgreSQL"
3. Railway automatically creates a PostgreSQL instance and provides `DATABASE_URL`

### 3. Configure Environment Variables

Railway automatically provides:
- `DATABASE_URL` - PostgreSQL connection string (auto-provided when PostgreSQL service is added)
- `PORT` - Railway automatically sets this (your app reads `process.env.PORT`)

No manual environment variable configuration needed for basic deployment.

### 4. Deploy

Railway automatically:
- Detects Node.js from `package.json`
- Runs `npm ci` to install dependencies (uses `package-lock.json`)
- Runs `npm start` to start the server
- Monitors the service and restarts on failures

**No Dockerfile, railway.json, or custom build configuration needed.**

## Verification

### 1. Check Deployment Status

1. Go to your Railway project dashboard
2. Verify the service shows "Active" status
3. Check logs for successful startup:
   - Should see "PostgreSQL connection established"
   - Should see "Database initialized successfully"
   - Should see "Listening on port {PORT}"

### 2. Test Health Endpoint

Open the Railway-provided URL (e.g., `https://your-app.railway.app/health`) in a browser or use curl:

```bash
curl https://your-app.railway.app/health
```

Expected response:
```json
{
  "status": "ok",
  "database": "connected",
  "timestamp": "2024-01-15T10:00:00.000Z"
}
```

### 3. Test Pairing Endpoint

Use the pairing endpoint to verify the API works:

```bash
curl -X POST https://your-app.railway.app/api/v1/pair \
  -H "Content-Type: application/json" \
  -d '{"pairing_code": "YOUR_CODE"}'
```

## Troubleshooting

### Build Failures

**Issue:** Build fails with npm errors

**Solution:**
- Ensure `package-lock.json` is committed to git
- Verify `package.json` has correct `scripts.start` field
- Check Railway logs for specific npm error messages

**Issue:** "DATABASE_URL is required" error

**Solution:**
- Ensure PostgreSQL service is added to the Railway project
- Railway automatically provides `DATABASE_URL` - no manual configuration needed
- Check that services are linked (if using separate services)

### Connection Errors

**Issue:** Health check returns `"database": "disconnected"`

**Solution:**
- Check Railway logs for PostgreSQL connection errors
- Verify PostgreSQL service is running (green status in Railway dashboard)
- Check that `DATABASE_URL` environment variable is set (should be auto-provided)

**Issue:** "ECONNREFUSED" or connection timeout

**Solution:**
- Verify PostgreSQL service is provisioned and running
- Check Railway service logs for PostgreSQL startup errors
- Ensure services are in the same project (Railway auto-links them)

### Schema Initialization Errors

**Issue:** Server starts but tables don't exist

**Solution:**
- Check server logs for schema initialization messages
- Verify PostgreSQL user has CREATE TABLE permissions
- Check for SQL syntax errors in logs (should be minimal with idempotent `IF NOT EXISTS`)

### Server Startup Failures

**Issue:** Server exits immediately after starting

**Solution:**
- Check Railway logs for error messages
- Verify `DATABASE_URL` is set correctly
- Check that database initialization completes successfully
- Server will exit with code 1 if DB initialization fails (fail-fast behavior)

## Environment Variables Reference

### Auto-Provided by Railway

- `DATABASE_URL` - PostgreSQL connection string (format: `postgresql://user:pass@host:port/dbname`)
- `PORT` - Port number (Railway sets this automatically)

### Required for Local Development

Create `backend/.env` file (not committed to git):

```
DATABASE_URL=postgresql://user:password@localhost:5432/gymdashsync
PORT=3001
```

## Deployment Best Practices

1. **Always commit `package-lock.json`** - Required for `npm ci` to work correctly
2. **Never commit `node_modules`** - Railway installs dependencies fresh
3. **Monitor logs** - Railway provides real-time logs in dashboard
4. **Use health checks** - Monitor `/health` endpoint for uptime monitoring
5. **Test after deployment** - Verify endpoints work before updating iOS app URLs

## Post-Deployment

After successful deployment:

1. Update iOS app `BackendConfig` to use Railway URL
2. Test pairing flow end-to-end
3. Verify data sync works
4. Monitor logs for any errors

## Next Steps

- See `docs/ios-app-v2-setup.md` for configuring iOS app to use Railway backend
- See `README.md` for overall project architecture

