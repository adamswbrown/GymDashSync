//
//  connection.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const { Pool } = require('pg');

// Require DATABASE_URL - fail fast if missing
const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) {
  throw new Error('DATABASE_URL environment variable is required');
}

// Parse DATABASE_URL (Railway format: postgresql://user:pass@host:port/dbname)
const pool = new Pool({
  connectionString: databaseUrl,
  ssl: databaseUrl.includes('railway.app') ? { rejectUnauthorized: false } : false,
  // Connection pool settings
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

// Test connection on startup
pool.on('connect', () => {
  console.log('PostgreSQL connection established');
});

pool.on('error', (err) => {
  console.error('Unexpected PostgreSQL pool error:', err);
  process.exit(-1);
});

// Export pool for use in queries
module.exports = pool;

// Export connection test function for /health endpoint
// Note: Logging is minimal to avoid noisy health check spam
let lastHealthCheckError = null;
module.exports.testConnection = async () => {
  try {
    const result = await pool.query('SELECT 1 as healthy');
    lastHealthCheckError = null; // Clear error on success
    return result.rows[0].healthy === 1;
  } catch (error) {
    // Only log if this is a new error (not repeated failures)
    if (lastHealthCheckError?.message !== error.message) {
      console.error('Database health check failed:', error.message);
      lastHealthCheckError = error;
    }
    return false;
  }
};
