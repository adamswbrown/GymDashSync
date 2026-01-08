//
//  init.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const pool = require('./connection');

/**
 * Initialize database schema
 * Creates tables and indexes if they don't exist
 * Uses PostgreSQL-native types: IDENTITY columns and TIMESTAMPTZ
 */
async function initializeDatabase() {
    console.log('Initializing PostgreSQL schema...');
    
    const client = await pool.connect();
    try {
        // Enable UUID extension if needed (optional, for future use)
        await client.query('CREATE EXTENSION IF NOT EXISTS "uuid-ossp"');
        
        // Create workouts table
        await client.query(`
            CREATE TABLE IF NOT EXISTS workouts (
                id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                client_id TEXT NOT NULL,
                source TEXT NOT NULL,
                workout_type TEXT NOT NULL,
                start_time TIMESTAMPTZ NOT NULL,
                end_time TIMESTAMPTZ NOT NULL,
                duration_seconds INTEGER NOT NULL,
                calories_active REAL,
                distance_meters REAL,
                avg_heart_rate REAL,
                source_device TEXT,
                healthkit_uuid TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        `);
        
        // Create profile_metrics table
        await client.query(`
            CREATE TABLE IF NOT EXISTS profile_metrics (
                id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                client_id TEXT NOT NULL,
                metric TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                measured_at TIMESTAMPTZ NOT NULL,
                source TEXT NOT NULL,
                healthkit_uuid TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        `);
        
        // Create clients table
        await client.query(`
            CREATE TABLE IF NOT EXISTS clients (
                id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                client_id TEXT NOT NULL UNIQUE,
                pairing_code TEXT NOT NULL UNIQUE,
                label TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        `);
        
        // Create warnings table
        await client.query(`
            CREATE TABLE IF NOT EXISTS warnings (
                id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                client_id TEXT NOT NULL,
                record_type TEXT NOT NULL,
                record_id INTEGER,
                warning_type TEXT NOT NULL,
                message TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        `);
        
        // Create indexes (idempotent with IF NOT EXISTS)
        const indexes = [
            'CREATE INDEX IF NOT EXISTS idx_workouts_client_id ON workouts(client_id)',
            'CREATE INDEX IF NOT EXISTS idx_workouts_start_time ON workouts(start_time)',
            'CREATE INDEX IF NOT EXISTS idx_workouts_client_start ON workouts(client_id, start_time)',
            'CREATE INDEX IF NOT EXISTS idx_workouts_uuid ON workouts(healthkit_uuid)',
            'CREATE INDEX IF NOT EXISTS idx_profile_metrics_client_id ON profile_metrics(client_id)',
            'CREATE INDEX IF NOT EXISTS idx_profile_metrics_metric ON profile_metrics(metric)',
            'CREATE INDEX IF NOT EXISTS idx_profile_metrics_client_measured ON profile_metrics(client_id, measured_at)',
            'CREATE INDEX IF NOT EXISTS idx_profile_metrics_uuid ON profile_metrics(healthkit_uuid)',
            'CREATE INDEX IF NOT EXISTS idx_clients_pairing_code ON clients(pairing_code)',
            'CREATE INDEX IF NOT EXISTS idx_clients_client_id ON clients(client_id)',
            'CREATE INDEX IF NOT EXISTS idx_warnings_client_id ON warnings(client_id)',
            'CREATE INDEX IF NOT EXISTS idx_warnings_created_at ON warnings(created_at)',
        ];
        
        for (const indexSql of indexes) {
            await client.query(indexSql);
        }
        
        console.log('PostgreSQL schema initialized successfully');
    } finally {
        client.release();
    }
}

module.exports = { initializeDatabase };
