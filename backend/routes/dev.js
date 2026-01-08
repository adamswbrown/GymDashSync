//
//  dev.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.
//
//  DEV ONLY - DO NOT USE IN PRODUCTION

const express = require('express');
const router = express.Router();
const asyncHandler = require('./asyncHandler');
const { 
    createClient, 
    insertWorkout, 
    insertProfileMetric,
    getAllClientsWithStats,
    getDedupStats
} = require('../db/queries');
const pool = require('../db/connection');

/**
 * Generate UUID v4
 */
function generateUUID() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}

/**
 * Generate pairing code
 */
function generatePairingCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    let code = '';
    for (let i = 0; i < 6; i++) {
        code += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return code;
}

/**
 * POST /dev/seed
 * Seed database with test data
 */
router.post('/seed', asyncHandler(async (req, res) => {
    console.log('[DEV] Seeding database...');
    
    // Create 2 test clients
    const client1Id = generateUUID();
    const client2Id = generateUUID();
    const code1 = generatePairingCode();
    const code2 = generatePairingCode();
    
    await createClient(client1Id, code1, 'Test Client 1');
    await createClient(client2Id, code2, 'Test Client 2');
    
    const now = new Date();
    
    // Add sample workouts for client 1 (including intentional duplicates)
    const baseTime = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000); // 7 days ago
    
    // Normal workout
    await insertWorkout({
        client_id: client1Id,
        source: 'apple_health',
        workout_type: 'run',
        start_time: new Date(baseTime.getTime() + 60 * 60 * 1000).toISOString(),
        end_time: new Date(baseTime.getTime() + 90 * 60 * 1000).toISOString(),
        duration_seconds: 1800,
        calories_active: 250,
        distance_meters: 5000,
        avg_heart_rate: 150,
        source_device: 'apple_watch'
    });
    
    // Duplicate workout (same time, similar duration)
    await insertWorkout({
        client_id: client1Id,
        source: 'apple_health',
        workout_type: 'run',
        start_time: new Date(baseTime.getTime() + 60 * 60 * 1000 + 30 * 1000).toISOString(), // 30 seconds later
        end_time: new Date(baseTime.getTime() + 90 * 60 * 1000 + 30 * 1000).toISOString(),
        duration_seconds: 1805, // 5 seconds difference (within 10% tolerance)
        calories_active: 250,
        distance_meters: 5000,
        avg_heart_rate: 150,
        source_device: 'apple_watch'
    });
    
    // Workout with validation warning (duration mismatch)
    await insertWorkout({
        client_id: client1Id,
        source: 'apple_health',
        workout_type: 'cycle',
        start_time: new Date(baseTime.getTime() + 2 * 60 * 60 * 1000).toISOString(),
        end_time: new Date(baseTime.getTime() + 3 * 60 * 60 * 1000).toISOString(),
        duration_seconds: 500, // Should be ~3600, way off
        calories_active: 300,
        distance_meters: 15000,
        source_device: 'apple_watch'
    });
    
    // Workout with unknown type (will be mapped to 'other')
    await insertWorkout({
        client_id: client1Id,
        source: 'apple_health',
        workout_type: 'unknown_type',
        start_time: new Date(baseTime.getTime() + 4 * 60 * 60 * 1000).toISOString(),
        end_time: new Date(baseTime.getTime() + 4.5 * 60 * 60 * 1000).toISOString(),
        duration_seconds: 1800,
        calories_active: 200,
        source_device: 'iphone'
    });
    
    // Add sample profile metrics
    await insertProfileMetric({
        client_id: client1Id,
        metric: 'weight',
        value: 75.5,
        unit: 'kg',
        measured_at: new Date(baseTime.getTime()).toISOString(),
        source: 'apple_health'
    });
    
    await insertProfileMetric({
        client_id: client1Id,
        metric: 'height',
        value: 175.0,
        unit: 'cm',
        measured_at: new Date(baseTime.getTime()).toISOString(),
        source: 'apple_health'
    });
    
    // Add workout for client 2
    await insertWorkout({
        client_id: client2Id,
        source: 'apple_health',
        workout_type: 'walk',
        start_time: new Date(baseTime.getTime() + 5 * 60 * 60 * 1000).toISOString(),
        end_time: new Date(baseTime.getTime() + 6 * 60 * 60 * 1000).toISOString(),
        duration_seconds: 3600,
        calories_active: 150,
        distance_meters: 4000,
        source_device: 'iphone'
    });
    
    console.log('[DEV] Seed completed');
    
    res.status(200).json({
        success: true,
        message: 'Database seeded with test data',
        clients: [
            { client_id: client1Id, pairing_code: code1 },
            { client_id: client2Id, pairing_code: code2 }
        ]
    });
}));

/**
 * GET /dev/health
 * Health check with assumption validation
 */
router.get('/health', asyncHandler(async (req, res) => {
    const clients = await getAllClientsWithStats();
    const stats = await getDedupStats();
    
    // Count warnings
    const warningsResult = await pool.query('SELECT COUNT(*) as count FROM warnings');
    const warningsCount = parseInt(warningsResult.rows[0].count);
    
    res.status(200).json({
        timestamp: new Date().toISOString(),
        assumptions: {
            total_clients: clients.length,
            total_workouts: stats?.total_workouts || 0,
            total_profile_metrics: stats?.total_profile_metrics || 0,
            warnings_count: warningsCount,
            clients_with_data: clients.filter(c => (parseInt(c.workouts_count) || 0) > 0).length
        },
        last_ingests: 'Check server logs for detailed ingest history',
        note: 'This is a DEV endpoint. Assumptions are validated through UI and logs.'
    });
}));

module.exports = router;
