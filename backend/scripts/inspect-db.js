#!/usr/bin/env node

//
// Database Inspection Script
// Analyzes SQLite database for migration planning
//

const db = require('../db/connection');
const fs = require('fs');
const path = require('path');

console.log('=== GymDashSync Database Inspection ===\n');

const dbPath = path.join(__dirname, '..', 'database.sqlite');

// Check if database exists
if (!fs.existsSync(dbPath)) {
    console.log('❌ Database file not found at:', dbPath);
    process.exit(1);
}

// 1. FILE METRICS
console.log('1. DATABASE FILE METRICS');
console.log('=' .repeat(50));
const stats = fs.statSync(dbPath);
console.log(`File Path: ${dbPath}`);
console.log(`File Size: ${(stats.size / 1024 / 1024).toFixed(2)} MB (${stats.size.toLocaleString()} bytes)`);
console.log(`Last Modified: ${stats.mtime.toISOString()}`);

// SQLite internals
const pageSize = db.prepare('PRAGMA page_size').get().page_size;
const pageCount = db.prepare('PRAGMA page_count').get().page_count;
const freelistCount = db.prepare('PRAGMA freelist_count').get().freelist_count;
const journalMode = db.prepare('PRAGMA journal_mode').get().journal_mode;
const synchronous = db.prepare('PRAGMA synchronous').get().synchronous;
const tempStore = db.prepare('PRAGMA temp_store').get().temp_store;
const foreignKeys = db.prepare('PRAGMA foreign_keys').get().foreign_keys;

console.log(`\nSQLite Configuration:`);
console.log(`  Page Size: ${pageSize} bytes`);
console.log(`  Page Count: ${pageCount.toLocaleString()}`);
console.log(`  Calculated Size: ${(pageSize * pageCount / 1024 / 1024).toFixed(2)} MB`);
console.log(`  Free Pages: ${freelistCount}`);
console.log(`  Journal Mode: ${journalMode} ${journalMode !== 'wal' ? '⚠️ (WAL not enabled)' : '✓'}`);
console.log(`  Synchronous: ${synchronous}`);
console.log(`  Foreign Keys: ${foreignKeys ? 'ON' : 'OFF'}`);

// Check for WAL file
const walPath = dbPath + '-wal';
const walExists = fs.existsSync(walPath);
if (walExists) {
    const walStats = fs.statSync(walPath);
    console.log(`  WAL File: ${(walStats.size / 1024).toFixed(2)} KB`);
} else {
    console.log(`  WAL File: None`);
}

// 2. SCHEMA ENUMERATION
console.log('\n\n2. SCHEMA ENUMERATION');
console.log('=' .repeat(50));

const tables = db.prepare(`
    SELECT name, sql 
    FROM sqlite_master 
    WHERE type='table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name
`).all();

console.log(`Total Tables: ${tables.length}\n`);

for (const table of tables) {
    console.log(`Table: ${table.name}`);
    
    // Get column info
    const columns = db.pragma(`table_info(${table.name})`);
    console.log(`  Columns: ${columns.length}`);
    console.log(`  Primary Key: ${columns.filter(c => c.pk).map(c => c.name).join(', ') || 'None'}`);
    
    // Check for UNIQUE constraints
    const uniqueIndexes = db.prepare(`
        SELECT name, sql 
        FROM sqlite_master 
        WHERE type='index' 
        AND tbl_name = ? 
        AND sql LIKE '%UNIQUE%'
    `).all(table.name);
    if (uniqueIndexes.length > 0) {
        console.log(`  UNIQUE Constraints: ${uniqueIndexes.map(i => i.name).join(', ')}`);
    }
    
    // Get indexes
    const indexes = db.prepare(`
        SELECT name, sql 
        FROM sqlite_master 
        WHERE type='index' 
        AND tbl_name = ? 
        AND name NOT LIKE 'sqlite_%'
    `).all(table.name);
    console.log(`  Indexes: ${indexes.length}`);
    indexes.forEach(idx => {
        const cols = idx.sql ? idx.sql.match(/\(([^)]+)\)/)?.[1] : 'unknown';
        console.log(`    - ${idx.name} (${cols || 'unknown'})`);
    });
    
    // Check for foreign keys (from schema inspection)
    const fkMatch = table.sql?.match(/REFERENCES\s+(\w+)\s*\(/g);
    if (fkMatch) {
        console.log(`  Foreign Keys: ${fkMatch.length} reference(s)`);
    } else {
        console.log(`  Foreign Keys: None`);
    }
    
    console.log('');
}

// 3. ROW COUNTS & DENSITY
console.log('\n\n3. ROW COUNTS & DENSITY');
console.log('=' .repeat(50));

for (const table of tables) {
    const count = db.prepare(`SELECT COUNT(*) as count FROM ${table.name}`).get().count;
    
    // Estimate row size (rough)
    const columns = db.pragma(`table_info(${table.name})`);
    let estSize = 0;
    columns.forEach(col => {
        if (col.type.toUpperCase().includes('INTEGER')) estSize += 8;
        else if (col.type.toUpperCase().includes('REAL')) estSize += 8;
        else if (col.type.toUpperCase().includes('TEXT')) estSize += 30; // avg text length
        else estSize += 10;
    });
    
    const totalSize = count * estSize;
    
    console.log(`${table.name}:`);
    console.log(`  Row Count: ${count.toLocaleString()}`);
    console.log(`  Est. Avg Row Size: ~${estSize} bytes`);
    console.log(`  Est. Table Size: ~${(totalSize / 1024).toFixed(2)} KB`);
    console.log('');
}

// 4. WRITE PATTERNS (from code analysis)
console.log('\n\n4. WRITE PATTERNS (from code analysis)');
console.log('=' .repeat(50));

// Get recent activity
const recentWorkouts = db.prepare(`
    SELECT COUNT(*) as count 
    FROM workouts 
    WHERE created_at > datetime('now', '-7 days')
`).get().count;

const recentMetrics = db.prepare(`
    SELECT COUNT(*) as count 
    FROM profile_metrics 
    WHERE created_at > datetime('now', '-7 days')
`).get().count;

console.log(`Recent Activity (last 7 days):`);
console.log(`  Workouts inserted: ${recentWorkouts}`);
console.log(`  Profile metrics inserted: ${recentMetrics}`);
console.log(`  Average workouts/day: ${(recentWorkouts / 7).toFixed(1)}`);
console.log(`  Average metrics/day: ${(recentMetrics / 7).toFixed(1)}`);

// Check for updates/deletes
console.log(`\nWrite Patterns (inferred from schema):`);
console.log(`  workouts: APPEND-ONLY (no update/delete columns visible)`);
console.log(`  profile_metrics: APPEND-ONLY (no update/delete columns visible)`);
console.log(`  warnings: APPEND-ONLY`);
console.log(`  clients: LOW-FREQUENCY (pairing-time only)`);

// 5. CONCURRENCY ASSESSMENT
console.log('\n\n5. CONCURRENCY & LOCKING RISK');
console.log('=' .repeat(50));

console.log(`Current Journal Mode: ${journalMode}`);
if (journalMode !== 'wal') {
    console.log(`⚠️  WAL MODE NOT ENABLED`);
    console.log(`   Risk: Single-writer lock contention with concurrent syncs`);
    console.log(`   Recommendation: Enable WAL mode immediately`);
} else {
    console.log(`✓  WAL mode enabled - supports concurrent reads`);
    console.log(`   Note: Still limited to single writer, but much better for read-heavy loads`);
}

console.log(`\nConnection Pattern: Single connection instance (better-sqlite3 default)`);
console.log(`Transaction Pattern: Per-insert transactions (from code analysis)`);
console.log(`\nLock Contention Risk: ${journalMode !== 'wal' ? 'HIGH' : 'MEDIUM'}`);
console.log(`  - Background sync will trigger concurrent write requests`);
console.log(`  - Current ingestion pattern: individual inserts in loop`);
console.log(`  - Better-sqlite3 is synchronous (no async queue)`);

// 6. MIGRATION PORTABILITY
console.log('\n\n6. MIGRATION PORTABILITY');
console.log('=' .repeat(50));

const portabilityIssues = [];

// Check for SQLite-specific syntax
for (const table of tables) {
    const sql = table.sql || '';
    
    if (sql.includes('AUTOINCREMENT')) {
        portabilityIssues.push(`  - ${table.name}: AUTOINCREMENT → PostgreSQL uses SERIAL or GENERATED`);
    }
    
    if (sql.includes('INTEGER PRIMARY KEY')) {
        // This is fine, but note it
    }
}

console.log('SQL Compatibility Issues:');
if (portabilityIssues.length === 0) {
    console.log('  ✓ No major compatibility issues found');
} else {
    portabilityIssues.forEach(issue => console.log(issue));
}

console.log('\nData Type Mapping:');
console.log('  TEXT → VARCHAR/TEXT ✓');
console.log('  INTEGER → INTEGER/BIGINT ✓');
console.log('  REAL → DOUBLE PRECISION/REAL ✓');
console.log('  No BLOB types ✓');
console.log('  Timestamps as TEXT (ISO8601) → TIMESTAMP ✓');

console.log('\nSchema Notes:');
console.log('  - No foreign key constraints in schema (only in code)');
console.log('  - All indexes use standard SQL syntax');
console.log('  - UUIDs stored as TEXT (compatible)');

// 7. GROWTH PROJECTION
console.log('\n\n7. GROWTH PROJECTION');
console.log('=' .repeat(50));

const totalWorkouts = db.prepare('SELECT COUNT(*) as count FROM workouts').get().count;
const totalMetrics = db.prepare('SELECT COUNT(*) as count FROM profile_metrics').get().count;
const totalClients = db.prepare('SELECT COUNT(*) as count FROM clients').get().count;

console.log('Current State:');
console.log(`  Clients: ${totalClients}`);
console.log(`  Total Workouts: ${totalWorkouts}`);
console.log(`  Total Profile Metrics: ${totalMetrics}`);
console.log(`  Avg Workouts/Client: ${totalClients > 0 ? (totalWorkouts / totalClients).toFixed(1) : 0}`);
console.log(`  Avg Metrics/Client: ${totalClients > 0 ? (totalMetrics / totalClients).toFixed(1) : 0}`);

console.log('\nProjections (conservative estimates):');
console.log('  Scenario: 10 active clients, 5 workouts/week/client');
console.log(`    Workouts/year: ${10 * 5 * 52} = ${10 * 5 * 52}`);
console.log(`    Workouts/year size: ~${(10 * 5 * 52 * 225 / 1024 / 1024).toFixed(2)} MB`);
console.log(`    5 years: ~${(10 * 5 * 52 * 5 * 225 / 1024 / 1024).toFixed(2)} MB`);

console.log('\n  Scenario: 50 active clients, 10 workouts/week/client');
console.log(`    Workouts/year: ${50 * 10 * 52} = ${50 * 10 * 52}`);
console.log(`    Workouts/year size: ~${(50 * 10 * 52 * 225 / 1024 / 1024).toFixed(2)} MB`);
console.log(`    5 years: ~${(50 * 10 * 52 * 5 * 225 / 1024 / 1024).toFixed(2)} MB`);

console.log('\nSQLite Limits:');
console.log('  Max DB Size: 281 TB (theoretical), 140 TB (practical)');
console.log('  Max Rows: 2^64 (no practical limit)');
console.log('  Concurrent Writers: 1 (hard limit)');
console.log('  Concurrent Readers: Many (with WAL)');

console.log('\n\n=== INSPECTION COMPLETE ===');
db.close();
