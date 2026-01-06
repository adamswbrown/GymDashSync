//
//  read.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const express = require('express');
const router = express.Router();
const { 
    getAllWorkouts, 
    getAllProfileMetrics,
    queryWorkoutsByUuids,
    queryProfileMetricsByUuids,
    getWorkoutsByClientId,
    getProfileMetricsByClientId,
    getWarningsByClientId
} = require('../db/queries');

/**
 * GET /workouts
 * Returns all workouts ordered by start_time DESC
 */
router.get('/workouts', (req, res) => {
    try {
        const workouts = getAllWorkouts();
        
        res.status(200).json(workouts);
        
    } catch (error) {
        console.error('[READ] Workouts error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

/**
 * GET /profile
 * Returns all profile metrics ordered by measured_at DESC
 */
router.get('/profile', (req, res) => {
    try {
        const metrics = getAllProfileMetrics();
        
        res.status(200).json(metrics);
        
    } catch (error) {
        console.error('[READ] Profile error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

/**
 * POST /workouts/query
 * Query workouts by UUIDs (for iOS client fetchObjects support)
 * Body: { "uuids": ["uuid1", "uuid2", ...] }
 * 
 * Note: Currently returns empty array (graceful degradation).
 * To enable proper matching, add healthkit_uuid column to workouts table.
 */
router.post('/workouts/query', (req, res) => {
    try {
        const { uuids } = req.body;
        
        if (!Array.isArray(uuids)) {
            return res.status(400).json({
                error: 'Request body must contain "uuids" array'
            });
        }
        
        // Returns empty array for now (graceful degradation)
        // iOS client will treat all records as new
        const workouts = queryWorkoutsByUuids(uuids);
        
        res.status(200).json(workouts);
        
    } catch (error) {
        console.error('[READ] Workouts query error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

/**
 * POST /profile-metrics/query
 * Query profile metrics by UUIDs (for iOS client fetchObjects support)
 * Body: { "uuids": ["uuid1", "uuid2", ...] }
 * 
 * Note: Currently returns empty array (graceful degradation).
 * To enable proper matching, add healthkit_uuid column to profile_metrics table.
 */
router.post('/profile-metrics/query', (req, res) => {
    try {
        const { uuids } = req.body;
        
        if (!Array.isArray(uuids)) {
            return res.status(400).json({
                error: 'Request body must contain "uuids" array'
            });
        }
        
        // Returns empty array for now (graceful degradation)
        // iOS client will treat all records as new
        const metrics = queryProfileMetricsByUuids(uuids);
        
        res.status(200).json(metrics);
        
    } catch (error) {
        console.error('[READ] Profile metrics query error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

/**
 * GET /clients/:client_id/workouts
 * Get workouts for a specific client
 */
router.get('/clients/:client_id/workouts', (req, res) => {
    try {
        const { client_id } = req.params;
        const limit = parseInt(req.query.limit) || 100;
        
        const workouts = getWorkoutsByClientId(client_id, limit);
        
        res.status(200).json(workouts);
        
    } catch (error) {
        console.error('[READ] Client workouts error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

/**
 * GET /clients/:client_id/profile
 * Get profile metrics for a specific client
 */
router.get('/clients/:client_id/profile', (req, res) => {
    try {
        const { client_id } = req.params;
        const limit = parseInt(req.query.limit) || 100;
        
        const metrics = getProfileMetricsByClientId(client_id, limit);
        
        res.status(200).json(metrics);
        
    } catch (error) {
        console.error('[READ] Client profile error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

/**
 * GET /clients/:client_id/warnings
 * Get warnings for a specific client
 */
router.get('/clients/:client_id/warnings', (req, res) => {
    try {
        const { client_id } = req.params;
        const limit = parseInt(req.query.limit) || 50;
        
        const warnings = getWarningsByClientId(client_id, limit);
        
        res.status(200).json(warnings);
        
    } catch (error) {
        console.error('[READ] Client warnings error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

module.exports = router;

