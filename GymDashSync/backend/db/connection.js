//
//  connection.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const Database = require('better-sqlite3');
const path = require('path');

// SQLite database file location
const dbPath = path.join(__dirname, '..', 'database.sqlite');

// Create database connection
// WAL mode is fine for SQLite, but we're keeping SQL portable for Postgres
const db = new Database(dbPath);

// Enable foreign keys (for future use, though we're not using them yet)
db.pragma('foreign_keys = ON');

// Log connection
console.log(`Database connected: ${dbPath}`);

module.exports = db;

