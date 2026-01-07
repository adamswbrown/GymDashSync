//
//  ingest.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const express = require('express');
const router = express.Router();
const { 
    insertWorkout, 
    insertProfileMetric, 
    clientExists,
    isDuplicateWorkout,
    createWarning,
    deleteWorkoutsByUuids,
    deleteProfileMetricsByUuids
} = require('../db/queries');
const { 
    validateWorkout, 
    validateProfileMetric, 
    validateClientId 
} = require('../db/validation');

/**
 * Handler for workout ingestion with validation and deduplication
 */
function handleWorkoutIngest(req, res) {
    const startTime = new Date();
    const timestamp = startTime.toISOString();
    
    try {
        const workouts = req.body;
        
        // Validate input is an array
        if (!Array.isArray(workouts)) {
            return res.status(400).json({
                success: false,
                error: 'Request body must be an array of workout objects'
            });
        }
        
        if (workouts.length === 0) {
            return res.status(200).json({
                success: true,
                count_received: 0,
                count_inserted: 0,
                duplicates_skipped: 0,
                warnings_count: 0,
                errors_count: 0
            });
        }
        
        // Extract and validate client_id
        const clientId = workouts[0]?.client_id;
        if (!clientId) {
            return res.status(400).json({
                success: false,
                error: 'client_id is required in workout payload'
            });
        }
        
        console.log(`[INGEST] Received workout batch with client_id=${clientId}, count=${workouts.length}`);
        
        // Validate client_id exists
        const clientValidation = validateClientId(clientId);
        if (!clientValidation.valid) {
            console.error(`[INGEST] Invalid client_id: ${clientId} - ${clientValidation.error}`);
            return res.status(400).json({
                success: false,
                error: clientValidation.error
            });
        }
        
        console.log(`[INGEST] Client_id validation passed: ${clientId}`);
        
        // Validate all workouts have the same client_id
        const allHaveClientId = workouts.every(w => w.client_id === clientId);
        if (!allHaveClientId) {
            return res.status(400).json({
                success: false,
                error: 'All workouts must have the same client_id'
            });
        }
        
        // Process each workout
        let inserted = 0;
        let duplicates = 0;
        let errors = 0;
        let warnings = 0;
        const errorsList = [];
        
        console.log(`[INGEST] Processing ${workouts.length} workout(s) for client_id=${clientId}`);
        console.log(`[INGEST] First workout sample: uuid=${workouts[0]?.healthkit_uuid || 'none'}, start_time=${workouts[0]?.start_time}, client_id=${workouts[0]?.client_id}`);
        
        for (const workout of workouts) {
            // Validate workout
            const validation = validateWorkout(workout, clientId);
            
            if (!validation.isValid) {
                errors++;
                errorsList.push(...validation.errors);
                continue;
            }
            
            // Check for duplicates first (before validation warnings)
            const isDup = isDuplicateWorkout(workout);
            if (isDup) {
                duplicates++;
                console.log(`[INGEST] Skipping duplicate workout: uuid=${workout.healthkit_uuid || 'none'}, start_time=${workout.start_time}, client_id=${workout.client_id}`);
                createWarning(clientId, 'workout', null, 'duplicate', 
                    `Duplicate workout skipped: start_time=${workout.start_time}, duration=${workout.duration_seconds}s`);
                continue;
            }
            
            console.log(`[INGEST] Inserting new workout: uuid=${workout.healthkit_uuid || 'none'}, start_time=${workout.start_time}, client_id=${workout.client_id}`);
            
            // Track warnings count
            if (validation.warnings.length > 0) {
                warnings += validation.warnings.length;
            }
            
            // Insert workout
            try {
                const result = insertWorkout(workout);
                console.log(`[INGEST] Successfully inserted workout ID=${result.lastInsertRowid}, uuid=${workout.healthkit_uuid || 'none'}`);
                // Store warnings with record ID after successful insert
                if (validation.warnings.length > 0 && result.lastInsertRowid) {
                    for (const warning of validation.warnings) {
                        createWarning(clientId, 'workout', result.lastInsertRowid, 'validation', warning);
                    }
                }
                inserted++;
            } catch (error) {
                console.error(`[INGEST] Failed to insert workout: ${error.message}, uuid=${workout.healthkit_uuid || 'none'}`);
                errors++;
                errorsList.push(`Failed to insert workout: ${error.message}`);
            }
        }
        
        // Log comprehensive ingest report
        const logMessage = `[INGEST] Workouts: timestamp=${timestamp}, client_id=${clientId}, ` +
            `received=${workouts.length}, inserted=${inserted}, duplicates=${duplicates}, ` +
            `warnings=${warnings}, errors=${errors}`;
        console.log(logMessage);
        
        if (errors > 0) {
            console.error(`[INGEST] Workouts errors: ${errorsList.join('; ')}`);
        }
        
        // Return detailed report
        res.status(errors === workouts.length ? 400 : 200).json({
            success: errors < workouts.length,
            count_received: workouts.length,
            count_inserted: inserted,
            duplicates_skipped: duplicates,
            warnings_count: warnings,
            errors_count: errors,
            errors: errors > 0 ? errorsList : undefined
        });
        
    } catch (error) {
        console.error('[INGEST] Workouts error:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
}

/**
 * Handler for profile metric ingestion with validation
 */
function handleProfileIngest(req, res) {
    const startTime = new Date();
    const timestamp = startTime.toISOString();
    
    try {
        const metrics = req.body;
        
        // Validate input is an array
        if (!Array.isArray(metrics)) {
            return res.status(400).json({
                success: false,
                error: 'Request body must be an array of profile metric objects'
            });
        }
        
        if (metrics.length === 0) {
            return res.status(200).json({
                success: true,
                count_received: 0,
                count_inserted: 0,
                warnings_count: 0,
                errors_count: 0
            });
        }
        
        // Extract and validate client_id
        const clientId = metrics[0]?.client_id;
        if (!clientId) {
            return res.status(400).json({
                success: false,
                error: 'client_id is required in profile metric payload'
            });
        }
        
        // Validate client_id exists
        const clientValidation = validateClientId(clientId);
        if (!clientValidation.valid) {
            return res.status(400).json({
                success: false,
                error: clientValidation.error
            });
        }
        
        // Validate all metrics have the same client_id
        const allHaveClientId = metrics.every(m => m.client_id === clientId);
        if (!allHaveClientId) {
            return res.status(400).json({
                success: false,
                error: 'All profile metrics must have the same client_id'
            });
        }
        
        // Process each metric
        let inserted = 0;
        let errors = 0;
        let warnings = 0;
        const errorsList = [];
        
        for (const metric of metrics) {
            // Validate metric
            const validation = validateProfileMetric(metric, clientId);
            
            if (!validation.isValid) {
                errors++;
                errorsList.push(...validation.errors);
                continue;
            }
            
            // Add warnings
            if (validation.warnings.length > 0) {
                warnings += validation.warnings.length;
                for (const warning of validation.warnings) {
                    createWarning(clientId, 'profile_metric', null, 'validation', warning);
                }
            }
            
            // Insert metric
            try {
                const result = insertProfileMetric(metric);
                // Store record ID for warning tracking
                if (validation.warnings.length > 0 && result.lastInsertRowid) {
                    for (const warning of validation.warnings) {
                        createWarning(clientId, 'profile_metric', result.lastInsertRowid, 'validation', warning);
                    }
                }
                inserted++;
            } catch (error) {
                errors++;
                errorsList.push(`Failed to insert metric: ${error.message}`);
            }
        }
        
        // Log comprehensive ingest report
        const logMessage = `[INGEST] Profile: timestamp=${timestamp}, client_id=${clientId}, ` +
            `received=${metrics.length}, inserted=${inserted}, warnings=${warnings}, errors=${errors}`;
        console.log(logMessage);
        
        if (errors > 0) {
            console.error(`[INGEST] Profile errors: ${errorsList.join('; ')}`);
        }
        
        // Return detailed report
        res.status(errors === metrics.length ? 400 : 200).json({
            success: errors < metrics.length,
            count_received: metrics.length,
            count_inserted: inserted,
            warnings_count: warnings,
            errors_count: errors,
            errors: errors > 0 ? errorsList : undefined
        });
        
    } catch (error) {
        console.error('[INGEST] Profile error:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
}

/**
 * POST /ingest/workouts or POST /api/v1/workouts
 * Accepts an array of workout objects and inserts them
 */
router.post('/workouts', handleWorkoutIngest);

/**
 * POST /ingest/profile or POST /api/v1/profile-metrics
 * Accepts an array of profile metric objects and inserts them
 */
router.post('/profile', handleProfileIngest);
router.post('/profile-metrics', handleProfileIngest);

/**
 * DELETE /workouts or DELETE /api/v1/workouts
 * Delete workouts by UUIDs
 */
router.delete('/workouts', (req, res) => {
    try {
        const { uuids } = req.body;
        
        if (!Array.isArray(uuids) || uuids.length === 0) {
            return res.status(400).json({
                success: false,
                error: 'Request body must contain a non-empty array of UUIDs'
            });
        }
        
        // Validate UUIDs are strings
        if (!uuids.every(uuid => typeof uuid === 'string')) {
            return res.status(400).json({
                success: false,
                error: 'All UUIDs must be strings'
            });
        }
        
        const deletedCount = deleteWorkoutsByUuids(uuids);
        
        console.log(`[DELETE] Workouts: deleted ${deletedCount} record(s) for ${uuids.length} UUID(s)`);
        
        res.status(200).json({
            success: true,
            count_requested: uuids.length,
            count_deleted: deletedCount
        });
        
    } catch (error) {
        console.error('[DELETE] Workouts error:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

/**
 * DELETE /profile-metrics or DELETE /api/v1/profile-metrics
 * Delete profile metrics by UUIDs
 */
router.delete('/profile-metrics', (req, res) => {
    try {
        const { uuids } = req.body;
        
        if (!Array.isArray(uuids) || uuids.length === 0) {
            return res.status(400).json({
                success: false,
                error: 'Request body must contain a non-empty array of UUIDs'
            });
        }
        
        // Validate UUIDs are strings
        if (!uuids.every(uuid => typeof uuid === 'string')) {
            return res.status(400).json({
                success: false,
                error: 'All UUIDs must be strings'
            });
        }
        
        const deletedCount = deleteProfileMetricsByUuids(uuids);
        
        console.log(`[DELETE] Profile metrics: deleted ${deletedCount} record(s) for ${uuids.length} UUID(s)`);
        
        res.status(200).json({
            success: true,
            count_requested: uuids.length,
            count_deleted: deletedCount
        });
        
    } catch (error) {
        console.error('[DELETE] Profile metrics error:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

module.exports = router;
