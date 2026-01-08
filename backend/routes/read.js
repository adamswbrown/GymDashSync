//
//  read.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const express = require('express');
const router = express.Router();
const asyncHandler = require('./asyncHandler');
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
router.get('/workouts', asyncHandler(async (req, res) => {
    const workouts = await getAllWorkouts();
    res.status(200).json(workouts);
}));

/**
 * GET /profile
 * Returns all profile metrics ordered by measured_at DESC
 */
router.get('/profile', asyncHandler(async (req, res) => {
    const metrics = await getAllProfileMetrics();
    res.status(200).json(metrics);
}));

/**
 * POST /workouts/query
 * Query workouts by UUIDs (for iOS client fetchObjects support)
 * Body: { "uuids": ["uuid1", "uuid2", ...] }
 */
router.post('/workouts/query', asyncHandler(async (req, res) => {
    const { uuids } = req.body;
    
    if (!Array.isArray(uuids)) {
        return res.status(400).json({
            error: 'Request body must contain "uuids" array'
        });
    }
    
    // Query workouts by UUID
    const workouts = await queryWorkoutsByUuids(uuids);
    console.log(`[READ] Query workouts: requested ${uuids.length} UUID(s), found ${workouts.length} match(es)`);
    if (uuids.length > 0 && workouts.length === 0) {
        console.log(`[READ] No UUID matches found - all ${uuids.length} workout(s) will be treated as new`);
    }
    
    res.status(200).json(workouts);
}));

/**
 * POST /profile-metrics/query
 * Query profile metrics by UUIDs (for iOS client fetchObjects support)
 * Body: { "uuids": ["uuid1", "uuid2", ...] }
 */
router.post('/profile-metrics/query', asyncHandler(async (req, res) => {
    const { uuids } = req.body;
    
    if (!Array.isArray(uuids)) {
        return res.status(400).json({
            error: 'Request body must contain "uuids" array'
        });
    }
    
    const metrics = await queryProfileMetricsByUuids(uuids);
    
    res.status(200).json(metrics);
}));

/**
 * GET /clients/:client_id/workouts
 * Get workouts for a specific client
 */
router.get('/clients/:client_id/workouts', asyncHandler(async (req, res) => {
    const { client_id } = req.params;
    const limit = parseInt(req.query.limit) || 100;
    
    const workouts = await getWorkoutsByClientId(client_id, limit);
    
    res.status(200).json(workouts);
}));

/**
 * GET /clients/:client_id/profile
 * Get profile metrics for a specific client
 */
router.get('/clients/:client_id/profile', asyncHandler(async (req, res) => {
    const { client_id } = req.params;
    const limit = parseInt(req.query.limit) || 100;
    
    const metrics = await getProfileMetricsByClientId(client_id, limit);
    
    res.status(200).json(metrics);
}));

/**
 * GET /clients/:client_id/warnings
 * Get warnings for a specific client
 */
router.get('/clients/:client_id/warnings', asyncHandler(async (req, res) => {
    const { client_id } = req.params;
    const limit = parseInt(req.query.limit) || 50;
    
    const warnings = await getWarningsByClientId(client_id, limit);
    
    res.status(200).json(warnings);
}));

module.exports = router;
