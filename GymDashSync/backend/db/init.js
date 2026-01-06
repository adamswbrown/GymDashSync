//
//  init.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const db = require('./connection');

/**
 * Initialize database schema
 * Creates tables and indexes if they don't exist
 * SQL is intentionally portable for PostgreSQL migration
 */
function initializeDatabase() {
    console.log('Initializing database schema...');
    
    // Create workouts table
    db.exec(`
        CREATE TABLE IF NOT EXISTS workouts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            client_id TEXT NOT NULL,
            source TEXT NOT NULL,
            workout_type TEXT NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            duration_seconds INTEGER NOT NULL,
            calories_active REAL,
            distance_meters REAL,
            avg_heart_rate REAL,
            source_device TEXT,
            created_at TEXT NOT NULL
        )
    `);
    
    // Create profile_metrics table
    db.exec(`
        CREATE TABLE IF NOT EXISTS profile_metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            client_id TEXT NOT NULL,
            metric TEXT NOT NULL,
            value REAL NOT NULL,
            unit TEXT NOT NULL,
            measured_at TEXT NOT NULL,
            source TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
    `);
    
    // Create clients table for pairing code management
    db.exec(`
        CREATE TABLE IF NOT EXISTS clients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            client_id TEXT NOT NULL UNIQUE,
            pairing_code TEXT NOT NULL UNIQUE,
            label TEXT,
            created_at TEXT NOT NULL
        )
    `);
    
    // Create warnings table for tracking data quality issues
    db.exec(`
        CREATE TABLE IF NOT EXISTS warnings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            client_id TEXT NOT NULL,
            record_type TEXT NOT NULL,
            record_id INTEGER,
            warning_type TEXT NOT NULL,
            message TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
    `);
    
    // Create indexes (safe for PostgreSQL)
    // Note: SQLite uses CREATE INDEX IF NOT EXISTS, PostgreSQL uses CREATE INDEX IF NOT EXISTS (both work)
    db.exec(`
        CREATE INDEX IF NOT EXISTS idx_workouts_client_id ON workouts(client_id);
        CREATE INDEX IF NOT EXISTS idx_workouts_start_time ON workouts(start_time);
        CREATE INDEX IF NOT EXISTS idx_workouts_client_start ON workouts(client_id, start_time);
        CREATE INDEX IF NOT EXISTS idx_profile_metrics_client_id ON profile_metrics(client_id);
        CREATE INDEX IF NOT EXISTS idx_profile_metrics_metric ON profile_metrics(metric);
        CREATE INDEX IF NOT EXISTS idx_profile_metrics_client_measured ON profile_metrics(client_id, measured_at);
        CREATE INDEX IF NOT EXISTS idx_clients_pairing_code ON clients(pairing_code);
        CREATE INDEX IF NOT EXISTS idx_clients_client_id ON clients(client_id);
        CREATE INDEX IF NOT EXISTS idx_warnings_client_id ON warnings(client_id);
        CREATE INDEX IF NOT EXISTS idx_warnings_created_at ON warnings(created_at);
    `);
    
    console.log('Database schema initialized successfully');
}

module.exports = { initializeDatabase };

