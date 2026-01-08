//
//  queries.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const pool = require('./connection');

/**
 * Insert a single workout record
 * @param {Object} workout - Workout object
 * @returns {Object} - Insert result with lastInsertRowid
 */
async function insertWorkout(workout) {
    const result = await pool.query(
        `INSERT INTO workouts (
            client_id, source, workout_type, start_time, end_time,
            duration_seconds, calories_active, distance_meters,
            avg_heart_rate, source_device, healthkit_uuid
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING id`,
        [
            workout.client_id,
            workout.source || 'apple_health',
            workout.workout_type,
            workout.start_time,  // ISO-8601 string, PostgreSQL coerces to TIMESTAMPTZ
            workout.end_time,    // ISO-8601 string, PostgreSQL coerces to TIMESTAMPTZ
            workout.duration_seconds,
            workout.calories_active || null,
            workout.distance_meters || null,
            workout.avg_heart_rate || null,
            workout.source_device || null,
            workout.healthkit_uuid || null,
            // created_at omitted - uses DEFAULT now()
        ]
    );
    return { lastInsertRowid: result.rows[0].id };
}

/**
 * Insert multiple workout records in a transaction
 * @param {Array} workouts - Array of workout objects
 * @returns {Number} - Number of records inserted
 */
async function insertWorkouts(workouts) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        let count = 0;
        
        for (const workout of workouts) {
            await client.query(
                `INSERT INTO workouts (
                    client_id, source, workout_type, start_time, end_time,
                    duration_seconds, calories_active, distance_meters,
                    avg_heart_rate, source_device, healthkit_uuid
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
                [
                    workout.client_id,
                    workout.source || 'apple_health',
                    workout.workout_type,
                    workout.start_time,  // PostgreSQL coerces ISO-8601 to TIMESTAMPTZ
                    workout.end_time,
                    workout.duration_seconds,
                    workout.calories_active || null,
                    workout.distance_meters || null,
                    workout.avg_heart_rate || null,
                    workout.source_device || null,
                    workout.healthkit_uuid || null,
                ]
            );
            count++;
        }
        
        await client.query('COMMIT');
        return count;
    } catch (error) {
        await client.query('ROLLBACK');
        throw error;
    } finally {
        client.release();
    }
}

/**
 * Insert a single profile metric record
 * @param {Object} metric - Profile metric object
 * @returns {Object} - Insert result with lastInsertRowid
 */
async function insertProfileMetric(metric) {
    const result = await pool.query(
        `INSERT INTO profile_metrics (
            client_id, metric, value, unit, measured_at, source, healthkit_uuid
        ) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
        [
            metric.client_id,
            metric.metric,
            metric.value,
            metric.unit,
            metric.measured_at,  // ISO-8601 string, PostgreSQL coerces to TIMESTAMPTZ
            metric.source || 'apple_health',
            metric.healthkit_uuid || null,
            // created_at omitted - uses DEFAULT now()
        ]
    );
    return { lastInsertRowid: result.rows[0].id };
}

/**
 * Insert multiple profile metric records in a transaction
 * @param {Array} metrics - Array of profile metric objects
 * @returns {Number} - Number of records inserted
 */
async function insertProfileMetrics(metrics) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        let count = 0;
        
        for (const metric of metrics) {
            await client.query(
                `INSERT INTO profile_metrics (
                    client_id, metric, value, unit, measured_at, source, healthkit_uuid
                ) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
                [
                    metric.client_id,
                    metric.metric,
                    metric.value,
                    metric.unit,
                    metric.measured_at,  // PostgreSQL coerces ISO-8601 to TIMESTAMPTZ
                    metric.source || 'apple_health',
                    metric.healthkit_uuid || null,
                ]
            );
            count++;
        }
        
        await client.query('COMMIT');
        return count;
    } catch (error) {
        await client.query('ROLLBACK');
        throw error;
    } finally {
        client.release();
    }
}

/**
 * Get all workouts, ordered by start_time DESC
 * @returns {Array} - Array of workout records
 */
async function getAllWorkouts() {
    const result = await pool.query(`
        SELECT * FROM workouts
        ORDER BY start_time DESC
    `);
    
    return result.rows;
}

/**
 * Get all profile metrics, ordered by measured_at DESC
 * @returns {Array} - Array of profile metric records
 */
async function getAllProfileMetrics() {
    const result = await pool.query(`
        SELECT * FROM profile_metrics
        ORDER BY measured_at DESC
    `);
    
    return result.rows;
}

/**
 * Query workouts by UUIDs (for fetchObjects support)
 * @param {Array} uuids - Array of UUID strings (HealthKit UUIDs)
 * @returns {Array} - Array of matching workout records
 */
async function queryWorkoutsByUuids(uuids) {
    if (!uuids || uuids.length === 0) {
        return [];
    }
    
    const result = await pool.query(
        'SELECT * FROM workouts WHERE healthkit_uuid = ANY($1::text[])',
        [uuids]
    );
    
    return result.rows;
}

/**
 * Query profile metrics by UUIDs (for fetchObjects support)
 * @param {Array} uuids - Array of UUID strings (HealthKit UUIDs)
 * @returns {Array} - Array of matching profile metric records
 */
async function queryProfileMetricsByUuids(uuids) {
    if (!uuids || uuids.length === 0) {
        return [];
    }
    
    const result = await pool.query(
        'SELECT * FROM profile_metrics WHERE healthkit_uuid = ANY($1::text[])',
        [uuids]
    );
    
    return result.rows;
}

/**
 * Get client_id by pairing code (case-insensitive)
 * @param {String} pairingCode - Pairing code to lookup
 * @returns {Object|null} - Client record or null if not found
 */
async function getClientByPairingCode(pairingCode) {
    const result = await pool.query(`
        SELECT client_id, pairing_code, created_at
        FROM clients
        WHERE UPPER(pairing_code) = UPPER($1)
        LIMIT 1
    `, [pairingCode]);
    
    return result.rows[0] || null;
}

/**
 * Create a new client with pairing code
 * @param {String} clientId - UUID for the client
 * @param {String} pairingCode - Pairing code (6-8 characters)
 * @param {String} label - Optional label for the client
 * @returns {Object} - Insert result
 */
async function createClient(clientId, pairingCode, label = null) {
    const result = await pool.query(
        `INSERT INTO clients (client_id, pairing_code, label)
        VALUES ($1, $2, $3) RETURNING id, client_id, pairing_code, label, created_at`,
        [clientId, pairingCode.toUpperCase(), label]
    );
    
    return result.rows[0];
}

/**
 * Check if client_id exists
 * @param {String} clientId - Client ID to check
 * @returns {Boolean} - True if client exists
 */
async function clientExists(clientId) {
    const result = await pool.query(
        'SELECT 1 FROM clients WHERE client_id = $1 LIMIT 1',
        [clientId]
    );
    
    return result.rows.length > 0;
}

/**
 * Check if workout is duplicate (same client_id, start_time within ±120 seconds, duration within ±10%)
 */
async function isDuplicateWorkout(workout) {
    // First check by UUID if available (more reliable)
    if (workout.healthkit_uuid) {
        const result = await pool.query(
            `SELECT id FROM workouts 
            WHERE client_id = $1 AND healthkit_uuid = $2`,
            [workout.client_id, workout.healthkit_uuid]
        );
        if (result.rows.length > 0) {
            console.log(`[DUPLICATE] UUID match found for workout ${workout.healthkit_uuid}, client ${workout.client_id}`);
            return true;
        }
    }
    
    // Fallback to time-based matching for workouts without UUID
    // Use native TIMESTAMPTZ math: ABS(EXTRACT(EPOCH FROM (start_time - $1))) <= 120
    const result = await pool.query(`
        SELECT id, start_time, duration_seconds
        FROM workouts
        WHERE client_id = $1
        AND ABS(EXTRACT(EPOCH FROM (start_time - $2::timestamptz))) <= 120
    `, [workout.client_id, workout.start_time]);
    
    if (result.rows.length > 0) {
        console.log(`[DUPLICATE] Found ${result.rows.length} candidate(s) for workout start_time=${workout.start_time}, client_id=${workout.client_id}`);
    }
    
    for (const candidate of result.rows) {
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
async function getWorkoutsByClientId(clientId, limit = 100) {
    const result = await pool.query(`
        SELECT * FROM workouts
        WHERE client_id = $1
        ORDER BY start_time DESC
        LIMIT $2
    `, [clientId, limit]);
    
    return result.rows;
}

/**
 * Get profile metrics for a specific client
 */
async function getProfileMetricsByClientId(clientId, limit = 100) {
    const result = await pool.query(`
        SELECT * FROM profile_metrics
        WHERE client_id = $1
        ORDER BY measured_at DESC
        LIMIT $2
    `, [clientId, limit]);
    
    return result.rows;
}

/**
 * Get client by client_id
 */
async function getClientById(clientId) {
    const result = await pool.query(`
        SELECT * FROM clients WHERE client_id = $1 LIMIT 1
    `, [clientId]);
    
    return result.rows[0] || null;
}

/**
 * Get all clients with summary stats
 */
async function getAllClientsWithStats() {
    const result = await pool.query(`
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
    
    return result.rows;
}

/**
 * Delete a client and all associated data (cascading delete)
 * @param {String} clientId - Client ID to delete
 * @returns {Object} - Deletion result with counts
 */
async function deleteClient(clientId) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        
        // Delete associated warnings first
        const warningsResult = await client.query(`DELETE FROM warnings WHERE client_id = $1`, [clientId]);
        
        // Delete associated workouts
        const workoutsResult = await client.query(`DELETE FROM workouts WHERE client_id = $1`, [clientId]);
        
        // Delete associated profile metrics
        const metricsResult = await client.query(`DELETE FROM profile_metrics WHERE client_id = $1`, [clientId]);
        
        // Finally, delete the client
        const clientResult = await client.query(`DELETE FROM clients WHERE client_id = $1`, [clientId]);
        
        if (clientResult.rowCount === 0) {
            await client.query('ROLLBACK');
            throw new Error('Client not found');
        }
        
        await client.query('COMMIT');
        
        return {
            client_deleted: clientResult.rowCount,
            workouts_deleted: workoutsResult.rowCount,
            metrics_deleted: metricsResult.rowCount,
            warnings_deleted: warningsResult.rowCount
        };
    } catch (error) {
        await client.query('ROLLBACK');
        throw error;
    } finally {
        client.release();
    }
}

/**
 * Create a warning record
 */
async function createWarning(clientId, recordType, recordId, warningType, message) {
    const result = await pool.query(
        `INSERT INTO warnings (client_id, record_type, record_id, warning_type, message)
        VALUES ($1, $2, $3, $4, $5) RETURNING id`,
        [clientId, recordType, recordId || null, warningType, message]
    );
    
    return result.rows[0];
}

/**
 * Get warnings for a client
 */
async function getWarningsByClientId(clientId, limit = 50) {
    const result = await pool.query(`
        SELECT * FROM warnings
        WHERE client_id = $1
        ORDER BY created_at DESC
        LIMIT $2
    `, [clientId, limit]);
    
    return result.rows;
}

/**
 * Delete workouts by UUIDs
 * @param {Array} uuids - Array of UUID strings (HealthKit UUIDs)
 * @returns {Number} - Number of records deleted
 */
async function deleteWorkoutsByUuids(uuids) {
    if (!uuids || uuids.length === 0) {
        return 0;
    }
    
    const result = await pool.query(
        'DELETE FROM workouts WHERE healthkit_uuid = ANY($1::text[])',
        [uuids]
    );
    
    return result.rowCount;
}

/**
 * Delete profile metrics by UUIDs
 * @param {Array} uuids - Array of UUID strings (HealthKit UUIDs)
 * @returns {Number} - Number of records deleted
 */
async function deleteProfileMetricsByUuids(uuids) {
    if (!uuids || uuids.length === 0) {
        return 0;
    }
    
    const result = await pool.query(
        'DELETE FROM profile_metrics WHERE healthkit_uuid = ANY($1::text[])',
        [uuids]
    );
    
    return result.rowCount;
}

/**
 * Get deduplication stats
 */
async function getDedupStats() {
    // Get basic stats
    const workoutsResult = await pool.query('SELECT COUNT(*) as count FROM workouts');
    const workoutsCount = parseInt(workoutsResult.rows[0].count);
    
    const metricsResult = await pool.query('SELECT COUNT(*) as count FROM profile_metrics');
    const metricsCount = parseInt(metricsResult.rows[0].count);
    
    const clientsResult = await pool.query('SELECT COUNT(*) as count FROM clients');
    const clientsCount = parseInt(clientsResult.rows[0].count);
    
    const warningsResult = await pool.query(`SELECT COUNT(*) as count FROM warnings WHERE warning_type = 'duplicate'`);
    const duplicatesSkipped = parseInt(warningsResult.rows[0].count);
    
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
