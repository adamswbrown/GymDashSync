#!/usr/bin/env node
//
//  check-schema.js
//  GymDashSync Backend
//
//  Quick script to check the current database schema, especially column types

const pool = require('../db/connection');

async function checkSchema() {
    const client = await pool.connect();
    try {
        console.log('Checking workouts table schema...\n');
        
        // Get column information for workouts table
        const result = await client.query(`
            SELECT 
                column_name,
                data_type,
                is_nullable,
                column_default
            FROM information_schema.columns
            WHERE table_name = 'workouts'
            ORDER BY ordinal_position;
        `);
        
        console.log('Workouts table columns:');
        console.log('─'.repeat(80));
        result.rows.forEach(row => {
            console.log(`${row.column_name.padEnd(25)} | ${row.data_type.padEnd(20)} | nullable: ${row.is_nullable}`);
        });
        console.log('─'.repeat(80));
        
        // Specifically check duration_seconds type
        const durationCheck = result.rows.find(r => r.column_name === 'duration_seconds');
        if (durationCheck) {
            console.log(`\n✓ duration_seconds column exists: ${durationCheck.data_type}`);
            if (durationCheck.data_type === 'real' || durationCheck.data_type === 'double precision') {
                console.log('  ✓ Column type is correct (REAL/DOUBLE PRECISION)');
            } else {
                console.log(`  ✗ Column type is ${durationCheck.data_type} - should be REAL`);
                console.log('  → Need to run migration: ALTER TABLE workouts ALTER COLUMN duration_seconds TYPE REAL;');
            }
        } else {
            console.log('\n✗ duration_seconds column not found!');
        }
        
        // Check if there are any workouts with non-integer duration values
        const sampleResult = await client.query(`
            SELECT 
                id,
                duration_seconds,
                workout_type,
                start_time
            FROM workouts
            ORDER BY created_at DESC
            LIMIT 5;
        `);
        
        if (sampleResult.rows.length > 0) {
            console.log('\nSample workout durations (last 5):');
            sampleResult.rows.forEach(row => {
                const duration = row.duration_seconds;
                const isDecimal = duration != null && duration % 1 !== 0;
                console.log(`  ID ${row.id}: ${duration} seconds ${isDecimal ? '(decimal ✓)' : '(integer)'}`);
            });
        } else {
            console.log('\nNo workouts in database yet.');
        }
        
    } catch (error) {
        console.error('Error checking schema:', error);
        process.exit(1);
    } finally {
        client.release();
        await pool.end();
    }
}

checkSchema();

