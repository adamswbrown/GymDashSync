#!/usr/bin/env node

//
//  create-pairing-code.js
//  GymDashSync Backend
//
//  Utility script to create a new client with pairing code
//  Usage: node scripts/create-pairing-code.js [pairing_code]
//

const { createClient } = require('../db/queries');
const { initializeDatabase } = require('../db/init');

// Initialize database
initializeDatabase();

// Generate pairing code or use provided one
const pairingCode = process.argv[2] || generatePairingCode();
const clientId = generateUUID();

try {
    createClient(clientId, pairingCode);
    console.log('✅ Client created successfully!');
    console.log(`   Pairing Code: ${pairingCode}`);
    console.log(`   Client ID: ${clientId}`);
    console.log('\n   Share the pairing code with the user to connect their device.');
} catch (error) {
    if (error.message.includes('UNIQUE constraint failed')) {
        console.error('❌ Error: Pairing code already exists');
        console.error('   Please use a different pairing code.');
    } else {
        console.error('❌ Error:', error.message);
    }
    process.exit(1);
}

function generatePairingCode() {
    // Generate a 6-character alphanumeric code
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // Exclude confusing chars
    let code = '';
    for (let i = 0; i < 6; i++) {
        code += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return code;
}

function generateUUID() {
    // Simple UUID v4 generator (for development use)
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}

