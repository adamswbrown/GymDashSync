//
//  queries.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const db = require('./connection');

/**
 * Insert a single workout record
 * @param {Object} workout - Workout object
 * @returns {Object} - Insert result with lastInsertRowid
 */
function insertWorkout(workout) {
    const stmt = db.prepare(`
        INSERT INTO workouts (
            client_id, source, workout_type, start_time, end_time,
            duration_seconds, calories_active, distance_meters,
            avg_heart_rate, source_device, healthkit_uuid, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    
    const now = new Date().toISOString();
    
    const result = stmt.run(
        workout.client_id,
        workout.source || 'apple_health',
        workout.workout_type,
        workout.start_time,
        workout.end_time,
        workout.duration_seconds,
        workout.calories_active || null,
        workout.distance_meters || null,
        workout.avg_heart_rate || null,
        workout.source_device || null,
        workout.healthkit_uuid || null,
        now
    );
    
    return { ...result, lastInsertRowid: result.lastInsertRowid };
}

/**
 * Insert multiple workout records in a transaction
 * @param {Array} workouts - Array of workout objects
 * @returns {Number} - Number of records inserted
 */
function insertWorkouts(workouts) {
    const insert = db.prepare(`
        INSERT INTO workouts (
            client_id, source, workout_type, start_time, end_time,
            duration_seconds, calories_active, distance_meters,
            avg_heart_rate, source_device, healthkit_uuid, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    
    const insertMany = db.transaction((workouts) => {
        const now = new Date().toISOString();
        let count = 0;
        
        for (const workout of workouts) {
            insert.run(
                workout.client_id,
                workout.source || 'apple_health',
                workout.workout_type,
                workout.start_time,
                workout.end_time,
                workout.duration_seconds,
                workout.calories_active || null,
                workout.distance_meters || null,
                workout.avg_heart_rate || null,
                workout.source_device || null,
                workout.healthkit_uuid || null,
                now
            );
            count++;
        }
        
        return count;
    });
    
    return insertMany(workouts);
}

/**
 * Insert a single profile metric record
 * @param {Object} metric - Profile metric object
 * @returns {Object} - Insert result with lastInsertRowid
 */
function insertProfileMetric(metric) {
    const stmt = db.prepare(`
        INSERT INTO profile_metrics (
            client_id, metric, value, unit, measured_at, source, healthkit_uuid, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    
    const now = new Date().toISOString();
    
    const result = stmt.run(
        metric.client_id,
        metric.metric,
        metric.value,
        metric.unit,
        metric.measured_at,
        metric.source || 'apple_health',
        metric.healthkit_uuid || null,
        now
    );
    
    return { ...result, lastInsertRowid: result.lastInsertRowid };
}

/**
 * Insert multiple profile metric records in a transaction
 * @param {Array} metrics - Array of profile metric objects
 * @returns {Number} - Number of records inserted
 */
function insertProfileMetrics(metrics) {
    const insert = db.prepare(`
        INSERT INTO profile_metrics (
            client_id, metric, value, unit, measured_at, source, healthkit_uuid, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    
    const insertMany = db.transaction((metrics) => {
        const now = new Date().toISOString();
        let count = 0;
        
        for (const metric of metrics) {
            insert.run(
                metric.client_id,
                metric.metric,
                metric.value,
                metric.unit,
                metric.measured_at,
                metric.source || 'apple_health',
                metric.healthkit_uuid || null,
                now
            );
            count++;
        }
        
        return count;
    });
    
    return insertMany(metrics);
}

/**
 * Get all workouts, ordered by start_time DESC
 * @returns {Array} - Array of workout records
 */
function getAllWorkouts() {
    const stmt = db.prepare(`
        SELECT * FROM workouts
        ORDER BY start_time DESC
    `);
    
    return stmt.all();
}

/**
 * Get all profile metrics, ordered by measured_at DESC
 * @returns {Array} - Array of profile metric records
 */
function getAllProfileMetrics() {
    const stmt = db.prepare(`
        SELECT * FROM profile_metrics
        ORDER BY measured_at DESC
    `);
    
    return stmt.all();
}

/**
 * Query workouts by UUIDs (for fetchObjects support)
 * @param {Array} uuids - Array of UUID strings (HealthKit UUIDs)
 * @returns {Array} - Array of matching workout records
 */
function queryWorkoutsByUuids(uuids) {
    if (!uuids || uuids.length === 0) {
        return [];
    }
    
    const placeholders = uuids.map(() => '?').join(',');
    const stmt = db.prepare(`
        SELECT * FROM workouts 
        WHERE healthkit_uuid IN (${placeholders})
    `);
    
    return stmt.all(...uuids);
}

/**
 * Query profile metrics by UUIDs (for fetchObjects support)
 * @param {Array} uuids - Array of UUID strings (HealthKit UUIDs)
 * @returns {Array} - Array of matching profile metric records
 */
function queryProfileMetricsByUuids(uuids) {
    if (!uuids || uuids.length === 0) {
        return [];
    }
    
    const placeholders = uuids.map(() => '?').join(',');
    const stmt = db.prepare(`
        SELECT * FROM profile_metrics 
        WHERE healthkit_uuid IN (${placeholders})
    `);
    
    return stmt.all(...uuids);
}

/**
 * Get client_id by pairing code (case-insensitive)
 * @param {String} pairingCode - Pairing code to lookup
 * @returns {Object|null} - Client record or null if not found
 */
function getClientByPairingCode(pairingCode) {
    const stmt = db.prepare(`
        SELECT client_id, pairing_code, created_at
        FROM clients
        WHERE UPPER(pairing_code) = UPPER(?)
        LIMIT 1
    `);
    
    return stmt.get(pairingCode) || null;
}

/**
 * Create a new client with pairing code
 * @param {String} clientId - UUID for the client
 * @param {String} pairingCode - Pairing code (6-8 characters)
 * @param {String} label - Optional label for the client
 * @returns {Object} - Insert result
 */
function createClient(clientId, pairingCode, label = null) {
    const stmt = db.prepare(`
        INSERT INTO clients (client_id, pairing_code, label, created_at)
        VALUES (?, ?, ?, ?)
    `);
    
    const now = new Date().toISOString();
    
    return stmt.run(clientId, pairingCode.toUpperCase(), label, now);
}

/**
 * Check if client_id exists
 * @param {String} clientId - Client ID to check
 * @returns {Boolean} - True if client exists
 */
function clientExists(clientId) {
    const stmt = db.prepare(`
        SELECT 1 FROM clients WHERE client_id = ? LIMIT 1
    `);
    
    return stmt.get(clientId) !== undefined;
}

/**
 * Check if workout is duplicate (same client_id, start_time within ±120 seconds, duration within ±10%)
 */
function isDuplicateWorkout(workout) {
    // First check by UUID if available (more reliable)
    if (workout.healthkit_uuid) {
        const uuidStmt = db.prepare(`
            SELECT id FROM workouts 
            WHERE client_id = ? AND healthkit_uuid = ?
        `);
        const uuidMatch = uuidStmt.get(workout.client_id, workout.healthkit_uuid);
        if (uuidMatch) {
            console.log(`[DUPLICATE] UUID match found for workout ${workout.healthkit_uuid}, client ${workout.client_id}`);
            return true;
        }
    }
    
    // Fallback to time-based matching for workouts without UUID
    // Convert ISO8601 to SQLite datetime for comparison
    // SQLite julianday function works with ISO8601 strings
    const stmt = db.prepare(`
        SELECT id, start_time, duration_seconds
        FROM workouts
        WHERE client_id = ?
        AND ABS(CAST((julianday(?) - julianday(start_time)) * 86400 AS INTEGER)) <= 120
    `);
    
    const candidates = stmt.all(workout.client_id, workout.start_time);
    
    if (candidates.length > 0) {
        console.log(`[DUPLICATE] Found ${candidates.length} candidate(s) for workout start_time=${workout.start_time}, client_id=${workout.client_id}`);
    }
    
    for (const candidate of candidates) {
        const candidateDuration = candidate.duration_seconds;
        const newDuration = workout.duration_seconds;
        const tolerance = Math.max(candidateDuration * 0.1, 10); // At least 10 seconds tolerance
        
        if (Math.abs(candidateDuration - newDuration) <= tolerance) {
            console.log(`[DUPLICATE] Duration match: candidate=${candidateDuration}s, new=${newDuration}s, tolerance=${tolerance}s`);
            return true;
        }
    }
    
    return false;
}

/**
 * Get workouts for a specific client
 */
function getWorkoutsByClientId(clientId, limit = 100) {
    const stmt = db.prepare(`
        SELECT * FROM workouts
        WHERE client_id = ?
        ORDER BY start_time DESC
        LIMIT ?
    `);
    
    return stmt.all(clientId, limit);
}

/**
 * Get profile metrics for a specific client
 */
function getProfileMetricsByClientId(clientId, limit = 100) {
    const stmt = db.prepare(`
        SELECT * FROM profile_metrics
        WHERE client_id = ?
        ORDER BY measured_at DESC
        LIMIT ?
    `);
    
    return stmt.all(clientId, limit);
}

/**
 * Get client by client_id
 */
function getClientById(clientId) {
    const stmt = db.prepare(`
        SELECT * FROM clients WHERE client_id = ? LIMIT 1
    `);
    
    return stmt.get(clientId) || null;
}

/**
 * Get all clients with summary stats
 */
function getAllClientsWithStats() {
    const stmt = db.prepare(`
        SELECT 
            c.*,
            COUNT(DISTINCT w.id) as workouts_count,
            MAX(w.start_time) as last_workout_start_time,
            COUNT(DISTINCT warn.id) as warnings_count
        FROM clients c
        LEFT JOIN workouts w ON c.client_id = w.client_id
        LEFT JOIN warnings warn ON c.client_id = warn.client_id
        GROUP BY c.id
        ORDER BY c.created_at DESC
    `);
    
    return stmt.all();
}

/**
 * Delete a client and all associated data (cascading delete)
 * @param {String} clientId - Client ID to delete
 * @returns {Object} - Deletion result with counts
 */
function deleteClient(clientId) {
    // Use a transaction to ensure all deletions succeed or fail together
    const deleteTransaction = db.transaction((clientId) => {
        // Delete associated warnings first
        const deleteWarnings = db.prepare(`DELETE FROM warnings WHERE client_id = ?`);
        const warningsResult = deleteWarnings.run(clientId);
        
        // Delete associated workouts
        const deleteWorkouts = db.prepare(`DELETE FROM workouts WHERE client_id = ?`);
        const workoutsResult = deleteWorkouts.run(clientId);
        
        // Delete associated profile metrics
        const deleteMetrics = db.prepare(`DELETE FROM profile_metrics WHERE client_id = ?`);
        const metricsResult = deleteMetrics.run(clientId);
        
        // Finally, delete the client
        const deleteClientStmt = db.prepare(`DELETE FROM clients WHERE client_id = ?`);
        const clientResult = deleteClientStmt.run(clientId);
        
        if (clientResult.changes === 0) {
            throw new Error('Client not found');
        }
        
        return {
            client_deleted: clientResult.changes,
            workouts_deleted: workoutsResult.changes,
            metrics_deleted: metricsResult.changes,
            warnings_deleted: warningsResult.changes
        };
    });
    
    return deleteTransaction(clientId);
}

/**
 * Create a warning record
 */
function createWarning(clientId, recordType, recordId, warningType, message) {
    const stmt = db.prepare(`
        INSERT INTO warnings (client_id, record_type, record_id, warning_type, message, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
    `);
    
    const now = new Date().toISOString();
    return stmt.run(clientId, recordType, recordId || null, warningType, message, now);
}

/**
 * Get warnings for a client
 */
function getWarningsByClientId(clientId, limit = 50) {
    const stmt = db.prepare(`
        SELECT * FROM warnings
        WHERE client_id = ?
        ORDER BY created_at DESC
        LIMIT ?
    `);
    
    return stmt.all(clientId, limit);
}

/**
 * Delete workouts by UUIDs
 * @param {Array} uuids - Array of UUID strings (HealthKit UUIDs)
 * @returns {Number} - Number of records deleted
 */
function deleteWorkoutsByUuids(uuids) {
    if (!uuids || uuids.length === 0) {
        return 0;
    }
    
    const placeholders = uuids.map(() => '?').join(',');
    const stmt = db.prepare(`
        DELETE FROM workouts 
        WHERE healthkit_uuid IN (${placeholders})
    `);
    
    const result = stmt.run(...uuids);
    return result.changes;
}

/**
 * Delete profile metrics by UUIDs
 * @param {Array} uuids - Array of UUID strings (HealthKit UUIDs)
 * @returns {Number} - Number of records deleted
 */
function deleteProfileMetricsByUuids(uuids) {
    if (!uuids || uuids.length === 0) {
        return 0;
    }
    
    const placeholders = uuids.map(() => '?').join(',');
    const stmt = db.prepare(`
        DELETE FROM profile_metrics 
        WHERE healthkit_uuid IN (${placeholders})
    `);
    
    const result = stmt.run(...uuids);
    return result.changes;
}

/**
 * Get deduplication stats
 */
function getDedupStats() {
    // Get basic stats
    const workoutsStmt = db.prepare('SELECT COUNT(*) as count FROM workouts');
    const workoutsCount = workoutsStmt.get().count;
    
    const metricsStmt = db.prepare('SELECT COUNT(*) as count FROM profile_metrics');
    const metricsCount = metricsStmt.get().count;
    
    const clientsStmt = db.prepare('SELECT COUNT(*) as count FROM clients');
    const clientsCount = clientsStmt.get().count;
    
    const warningsStmt = db.prepare(`SELECT COUNT(*) as count FROM warnings WHERE warning_type = 'duplicate'`);
    const duplicatesSkipped = warningsStmt.get().count;
    
    return {
        total_clients: clientsCount,
        total_workouts: workoutsCount,
        total_profile_metrics: metricsCount,
        duplicates_skipped: duplicatesSkipped
    };
}

module.exports = {
    insertWorkout,
    insertWorkouts,
    insertProfileMetric,
    insertProfileMetrics,
    getAllWorkouts,
    getAllProfileMetrics,
    queryWorkoutsByUuids,
    queryProfileMetricsByUuids,
    deleteWorkoutsByUuids,
    deleteProfileMetricsByUuids,
    getClientByPairingCode,
    createClient,
    clientExists,
    isDuplicateWorkout,
    getWorkoutsByClientId,
    getProfileMetricsByClientId,
    getClientById,
    getAllClientsWithStats,
    deleteClient,
    createWarning,
    getWarningsByClientId,
    getDedupStats
};

