//
//  pair.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const express = require('express');
const router = express.Router();
const asyncHandler = require('./asyncHandler');
const { getClientByPairingCode } = require('../db/queries');

/**
 * POST /pair
 * Exchange pairing code for client_id
 * 
 * Request: { "pairing_code": "ABC123" }
 * Response: { "client_id": "uuid" } or { "error": "invalid pairing code" }
 */
router.post('/', asyncHandler(async (req, res) => {
    const { pairing_code } = req.body;
    
    // Validate input
    if (!pairing_code || typeof pairing_code !== 'string' || pairing_code.trim().length === 0) {
        return res.status(400).json({
            error: 'pairing_code is required'
        });
    }
    
    // Lookup client by pairing code (case-insensitive)
    const client = await getClientByPairingCode(pairing_code.trim());
    
    if (!client) {
        console.log(`[PAIR] Invalid pairing code attempted: ${pairing_code}`);
        return res.status(404).json({
            error: 'invalid pairing code'
        });
    }
    
    console.log(`[PAIR] Successful pairing: code=${pairing_code}, client_id=${client.client_id}`);
    
    res.status(200).json({
        client_id: client.client_id
    });
}));

module.exports = router;
