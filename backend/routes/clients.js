//
//  clients.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const express = require('express');
const router = express.Router();
const { createClient, getAllClientsWithStats, getClientById } = require('../db/queries');

/**
 * Generate a human-friendly pairing code
 */
function generatePairingCode() {
    // Exclude ambiguous characters: 0, O, 1, I
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    let code = '';
    for (let i = 0; i < 6; i++) {
        code += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return code;
}

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
 * POST /clients
 * Create a new client with pairing code
 */
router.post('/', (req, res) => {
    try {
        const { label } = req.body;
        
        // Generate client_id and pairing_code
        const clientId = generateUUID();
        let pairingCode = generatePairingCode();
        
        // Ensure uniqueness (retry if collision)
        let attempts = 0;
        while (attempts < 10) {
            try {
                createClient(clientId, pairingCode, label || null);
                break;
            } catch (error) {
                if (error.message.includes('UNIQUE constraint failed') && error.message.includes('pairing_code')) {
                    pairingCode = generatePairingCode();
                    attempts++;
                } else {
                    throw error;
                }
            }
        }
        
        if (attempts >= 10) {
            return res.status(500).json({
                error: 'Failed to generate unique pairing code after multiple attempts'
            });
        }
        
        console.log(`[CLIENTS] Created: client_id=${clientId}, pairing_code=${pairingCode}, label=${label || 'none'}`);
        
        res.status(201).json({
            client_id: clientId,
            pairing_code: pairingCode,
            label: label || null
        });
        
    } catch (error) {
        console.error('[CLIENTS] Create error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

/**
 * GET /clients
 * List all clients with summary stats
 */
router.get('/', (req, res) => {
    try {
        const clients = getAllClientsWithStats();
        
        // Format response
        const formatted = clients.map(client => ({
            id: client.id,
            client_id: client.client_id,
            pairing_code: client.pairing_code,
            label: client.label,
            created_at: client.created_at,
            workouts_count: client.workouts_count || 0,
            last_workout_start_time: client.last_workout_start_time || null,
            warnings_count: client.warnings_count || 0
        }));
        
        res.status(200).json(formatted);
        
    } catch (error) {
        console.error('[CLIENTS] List error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

/**
 * GET /clients/:client_id
 * Get a specific client
 */
router.get('/:client_id', (req, res) => {
    try {
        const { client_id } = req.params;
        const client = getClientById(client_id);
        
        if (!client) {
            return res.status(404).json({
                error: 'Client not found'
            });
        }
        
        res.status(200).json(client);
        
    } catch (error) {
        console.error('[CLIENTS] Get error:', error);
        res.status(500).json({
            error: error.message
        });
    }
});

module.exports = router;

