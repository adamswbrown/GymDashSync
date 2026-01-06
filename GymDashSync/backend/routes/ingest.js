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
    createWarning
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
        
        // Validate client_id exists
        const clientValidation = validateClientId(clientId);
        if (!clientValidation.valid) {
            return res.status(400).json({
                success: false,
                error: clientValidation.error
            });
        }
        
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
        
        for (const workout of workouts) {
            // Validate workout
            const validation = validateWorkout(workout, clientId);
            
            if (!validation.isValid) {
                errors++;
                errorsList.push(...validation.errors);
                continue;
            }
            
            // Check for duplicates first (before validation warnings)
            if (isDuplicateWorkout(workout)) {
                duplicates++;
                createWarning(clientId, 'workout', null, 'duplicate', 
                    `Duplicate workout skipped: start_time=${workout.start_time}, duration=${workout.duration_seconds}s`);
                continue;
            }
            
            // Track warnings count
            if (validation.warnings.length > 0) {
                warnings += validation.warnings.length;
            }
            
            // Insert workout
            try {
                const result = insertWorkout(workout);
                // Store warnings with record ID after successful insert
                if (validation.warnings.length > 0 && result.lastInsertRowid) {
                    for (const warning of validation.warnings) {
                        createWarning(clientId, 'workout', result.lastInsertRowid, 'validation', warning);
                    }
                }
                inserted++;
            } catch (error) {
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

module.exports = router;
