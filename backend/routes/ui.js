//
//  ui.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const express = require('express');
const router = express.Router();
const asyncHandler = require('./asyncHandler');
const path = require('path');
const fs = require('fs');
const { 
    getAllClientsWithStats, 
    getClientById,
    getWorkoutsByClientId,
    getProfileMetricsByClientId,
    getWarningsByClientId,
    deleteClient,
    createClient
} = require('../db/queries');

/**
 * Generate a human-friendly pairing code
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
 * Format date for display
 */
function formatDate(dateString) {
    if (!dateString) return 'Never';
    try {
        const date = new Date(dateString);
        return date.toLocaleString();
    } catch {
        return dateString;
    }
}

/**
 * Format duration in minutes
 */
function formatDuration(seconds) {
    if (!seconds) return '-';
    const mins = Math.floor(seconds / 60);
    return `${mins} min`;
}

/**
 * Format distance in km
 */
function formatDistance(meters) {
    if (!meters) return '-';
    return `${(meters / 1000).toFixed(2)} km`;
}

/**
 * GET /ui
 * Landing page with list of clients
 */
router.get('/', asyncHandler(async (req, res) => {
    const clients = await getAllClientsWithStats();
    
    let html = '<h2>Clients</h2>';
    html += '<div style="margin-bottom: 20px;">';
    html += '<a href="/ui/clients/new" class="btn">Create New Client</a> ';
    html += '<a href="/ui/diagnostics/schema" class="btn" style="background-color: #6c757d;">🔧 Schema Diagnostics</a>';
    html += '</div>';
    
    if (clients.length === 0) {
        html += '<p style="margin-top: 20px;">No clients yet. Create your first client to get started.</p>';
    } else {
        html += '<table>';
        html += '<thead><tr><th>Label</th><th>Client ID</th><th>Pairing Code</th><th>Workouts</th><th>Last Workout</th><th>Warnings</th><th>Action</th></tr></thead>';
        html += '<tbody>';
        
        for (const client of clients) {
            const warningsCount = parseInt(client.warnings_count) || 0;
            const workoutsCount = parseInt(client.workouts_count) || 0;
            const warningsBadge = warningsCount > 0 
                ? `<span class="warning">⚠️ ${warningsCount}</span>` 
                : '0';
            
            html += `<tr>`;
            html += `<td>${client.label || '<em>No label</em>'}</td>`;
            html += `<td><span class="code">${client.client_id.substring(0, 8)}...</span></td>`;
            html += `<td><span class="code">${client.pairing_code}</span></td>`;
            html += `<td>${workoutsCount}</td>`;
            html += `<td>${formatDate(client.last_workout_start_time)}</td>`;
            html += `<td>${warningsBadge}</td>`;
            const clientLabelEscaped = (client.label || 'Client').replace(/'/g, "\\'").replace(/"/g, '&quot;').replace(/\n/g, ' ');
            html += `<td>`;
            html += `<a href="/ui/clients/${client.client_id}" class="btn btn-secondary">View</a>`;
            html += `<button onclick="deleteClient('${client.client_id}', '${clientLabelEscaped}', ${workoutsCount})" class="btn" style="margin-left: 5px; background-color: #dc2626; color: white; font-size: 12px; padding: 5px 10px;">Delete</button>`;
            html += `</td>`;
            html += `</tr>`;
        }
        
        html += '</tbody></table>';
        
        // Add JavaScript for delete confirmation
        html += '<script>';
        html += 'function deleteClient(clientId, clientLabel, workoutsCount) {';
        html += '    if (confirm("Are you sure you want to delete client \\"" + clientLabel + "\\"?\\n\\nThis will permanently delete:\\n- The client record\\n- All associated workouts (" + workoutsCount + ")\\n- All associated profile metrics\\n- All associated warnings\\n\\nThis action cannot be undone.")) {';
        html += '        const form = document.createElement("form");';
        html += '        form.method = "POST";';
        html += '        form.action = "/ui/clients/" + clientId + "/delete";';
        html += '        const methodInput = document.createElement("input");';
        html += '        methodInput.type = "hidden";';
        html += '        methodInput.name = "_method";';
        html += '        methodInput.value = "DELETE";';
        html += '        form.appendChild(methodInput);';
        html += '        document.body.appendChild(form);';
        html += '        form.submit();';
        html += '    }';
        html += '}';
        html += '</script>';
    }
    
    const layoutPath = path.join(__dirname, '../views/layout.html');
    const layout = fs.readFileSync(layoutPath, 'utf8')
        .replace('{{title}}', 'Clients')
        .replace('{{content}}', html);
    res.send(layout);
}));

/**
 * GET /ui/clients/new
 * Create client form
 */
router.get('/clients/new', (req, res) => {
    let html = '<h2>Create New Client</h2>';
    html += '<form method="POST" action="/ui/clients">';
    html += '<div class="form-group">';
    html += '<label for="label">Label (optional)</label>';
    html += '<input type="text" id="label" name="label" placeholder="e.g., John Doe">';
    html += '</div>';
    html += '<button type="submit" class="btn">Create Client</button>';
    html += '<a href="/ui" class="btn btn-secondary" style="margin-left: 10px;">Cancel</a>';
    html += '</form>';
    
    const layoutPath = path.join(__dirname, '../views/layout.html');
    const layout = fs.readFileSync(layoutPath, 'utf8')
        .replace('{{title}}', 'Create Client')
        .replace('{{content}}', html);
    res.send(layout);
});

/**
 * POST /ui/clients
 * Handle client creation
 */
router.post('/clients', asyncHandler(async (req, res) => {
    const { label } = req.body;
    
    const clientId = generateUUID();
    let pairingCode = generatePairingCode();
    
    // Ensure uniqueness
    let attempts = 0;
    while (attempts < 10) {
        try {
            await createClient(clientId, pairingCode, label || null);
            break;
        } catch (error) {
            // PostgreSQL error messages differ from SQLite
            if (error.message && error.message.includes('duplicate key value') && error.message.includes('pairing_code')) {
                pairingCode = generatePairingCode();
                attempts++;
            } else {
                throw error;
            }
        }
    }
    
    if (attempts >= 10) {
        return res.status(500).send('<h2>Error</h2><p>Failed to generate unique pairing code</p>');
    }
    
    let html = '<h2>Client Created Successfully</h2>';
    html += '<div style="background: #f0f9ff; padding: 20px; border-radius: 8px; margin: 20px 0;">';
    html += '<h3 style="margin-bottom: 15px;">Pairing Code</h3>';
    html += `<p style="font-size: 32px; font-weight: bold; color: #2563eb; font-family: monospace; margin: 10px 0;">${pairingCode}</p>`;
    html += '<p style="color: #6b7280;">Share this code with the client to connect their device.</p>';
    html += '</div>';
    html += '<div style="margin-top: 20px;">';
    html += `<p><strong>Client ID:</strong> <span class="code">${clientId}</span></p>`;
    if (label) {
        html += `<p><strong>Label:</strong> ${label}</p>`;
    }
    html += '</div>';
    html += '<div style="margin-top: 20px;">';
    html += `<a href="/ui/clients/${clientId}" class="btn">View Client</a>`;
    html += '<a href="/ui" class="btn btn-secondary" style="margin-left: 10px;">Back to Clients</a>';
    html += '</div>';
    
    const layoutPath = path.join(__dirname, '../views/layout.html');
    const layout = fs.readFileSync(layoutPath, 'utf8')
        .replace('{{title}}', 'Client Created')
        .replace('{{content}}', html);
    res.send(layout);
}));

/**
 * GET /ui/clients/:client_id
 * Client detail page
 */
router.get('/clients/:client_id', asyncHandler(async (req, res) => {
    const { client_id } = req.params;
    const client = await getClientById(client_id);
    
    if (!client) {
        return res.status(404).send('<h2>Client Not Found</h2><p><a href="/ui">Back to Clients</a></p>');
    }
    
    const workouts = await getWorkoutsByClientId(client_id, 50);
    const metrics = await getProfileMetricsByClientId(client_id, 50);
    const warnings = await getWarningsByClientId(client_id, 50);
    
    let html = `<h2>${client.label || 'Client'}</h2>`;
    
    // Header info
    html += '<div class="stats">';
    html += `<div class="stat-card"><div class="stat-label">Client ID</div><div class="stat-value" style="font-size: 14px;">${client.client_id}</div></div>`;
    html += `<div class="stat-card"><div class="stat-label">Pairing Code</div><div class="stat-value" style="font-size: 18px;">${client.pairing_code}</div></div>`;
    html += `<div class="stat-card"><div class="stat-label">Workouts</div><div class="stat-value">${workouts.length}</div></div>`;
    html += `<div class="stat-card"><div class="stat-label">Warnings</div><div class="stat-value ${warnings.length > 0 ? 'warning' : ''}">${warnings.length}</div></div>`;
    html += '</div>';
    
    // Recent Workouts
    html += '<h3 style="margin-top: 30px;">Recent Workouts</h3>';
    if (workouts.length === 0) {
        html += '<p>No workouts yet.</p>';
    } else {
        html += '<table>';
        html += '<thead><tr><th>Start Time</th><th>Type</th><th>Duration</th><th>Distance</th><th>Calories</th><th>Avg HR</th><th>Device</th><th>⚠️</th></tr></thead>';
        html += '<tbody>';
        
        for (const workout of workouts) {
            // Check if this workout has warnings (match by record_id)
            const workoutWarnings = warnings.filter(w => 
                w.record_type === 'workout' && w.record_id === workout.id
            );
            const warningIcon = workoutWarnings.length > 0 ? '⚠️' : '';
            
            html += `<tr>`;
            html += `<td>${formatDate(workout.start_time)}</td>`;
            html += `<td>${workout.workout_type}</td>`;
            html += `<td>${formatDuration(workout.duration_seconds)}</td>`;
            html += `<td>${formatDistance(workout.distance_meters)}</td>`;
            html += `<td>${workout.calories_active ? workout.calories_active.toFixed(0) : '-'}</td>`;
            html += `<td>${workout.avg_heart_rate ? workout.avg_heart_rate.toFixed(0) : '-'}</td>`;
            html += `<td>${workout.source_device || '-'}</td>`;
            html += `<td>${warningIcon}</td>`;
            html += `</tr>`;
        }
        
        html += '</tbody></table>';
    }
    
    // Profile Metrics
    html += '<h3 style="margin-top: 30px;">Profile Metrics</h3>';
    if (metrics.length === 0) {
        html += '<p>No profile metrics yet.</p>';
    } else {
        html += '<table>';
        html += '<thead><tr><th>Measured At</th><th>Metric</th><th>Value</th><th>Unit</th><th>⚠️</th></tr></thead>';
        html += '<tbody>';
        
        for (const metric of metrics) {
            // Check if this metric has warnings (match by record_id)
            const metricWarnings = warnings.filter(w => 
                w.record_type === 'profile_metric' && w.record_id === metric.id
            );
            const warningIcon = metricWarnings.length > 0 ? '⚠️' : '';
            
            html += `<tr>`;
            html += `<td>${formatDate(metric.measured_at)}</td>`;
            html += `<td>${metric.metric}</td>`;
            html += `<td>${metric.value}</td>`;
            html += `<td>${metric.unit}</td>`;
            html += `<td>${warningIcon}</td>`;
            html += `</tr>`;
        }
        
        html += '</tbody></table>';
    }
    
    // Data Quality Warnings
    if (warnings.length > 0) {
        html += '<h3 style="margin-top: 30px;">Data Quality Warnings</h3>';
        html += '<table>';
        html += '<thead><tr><th>Time</th><th>Type</th><th>Warning</th></tr></thead>';
        html += '<tbody>';
        
        for (const warning of warnings) {
            html += `<tr>`;
            html += `<td>${formatDate(warning.created_at)}</td>`;
            html += `<td>${warning.warning_type}</td>`;
            html += `<td>${warning.message}</td>`;
            html += `</tr>`;
        }
        
        html += '</tbody></table>';
    }
    
    const clientLabelEscaped = (client.label || 'Client').replace(/'/g, "\\'").replace(/"/g, '&quot;').replace(/\n/g, ' ');
    html += '<div style="margin-top: 30px;">';
    html += '<a href="/ui" class="btn">Back to Clients</a>';
    html += '<button onclick="deleteClient(\'' + client.client_id + '\', \'' + clientLabelEscaped + '\')" class="btn" style="margin-left: 10px; background-color: #dc2626; color: white;">Delete Client</button>';
    html += '</div>';
    
    // Add JavaScript for delete confirmation
    html += '<script>';
    html += 'function deleteClient(clientId, clientLabel) {';
    html += '    if (confirm("Are you sure you want to delete client \\"" + clientLabel + "\\"?\\n\\nThis will permanently delete:\\n- The client record\\n- All associated workouts (' + workouts.length + ')\\n- All associated profile metrics (' + metrics.length + ')\\n- All associated warnings (' + warnings.length + ')\\n\\nThis action cannot be undone.")) {';
    html += '        const form = document.createElement("form");';
    html += '        form.method = "POST";';
    html += '        form.action = "/ui/clients/" + clientId + "/delete";';
    html += '        const methodInput = document.createElement("input");';
    html += '        methodInput.type = "hidden";';
    html += '        methodInput.name = "_method";';
    html += '        methodInput.value = "DELETE";';
    html += '        form.appendChild(methodInput);';
    html += '        document.body.appendChild(form);';
    html += '        form.submit();';
    html += '    }';
    html += '}';
    html += '</script>';
    
    const layoutPath = path.join(__dirname, '../views/layout.html');
    const layout = fs.readFileSync(layoutPath, 'utf8')
        .replace('{{title}}', client.label || 'Client')
        .replace('{{content}}', html);
    res.send(layout);
}));

/**
 * POST /ui/clients/:client_id/delete
 * Handle client deletion (POST method for form submission, then DELETE internally)
 */
router.post('/clients/:client_id/delete', asyncHandler(async (req, res) => {
    const { client_id } = req.params;
    
    // Verify client exists
    const client = await getClientById(client_id);
    if (!client) {
        return res.status(404).send('<h2>Client Not Found</h2><p><a href="/ui">Back to Clients</a></p>');
    }
    
    // Delete the client and all associated data
    const result = await deleteClient(client_id);
    
    console.log(`[UI] Deleted client: client_id=${client_id}, workouts=${result.workouts_deleted}, metrics=${result.metrics_deleted}, warnings=${result.warnings_deleted}`);
    
    // Show success page
    let html = '<h2>Client Deleted Successfully</h2>';
    html += '<div style="background: #f0f9ff; padding: 20px; border-radius: 8px; margin: 20px 0;">';
    html += `<p><strong>Client:</strong> ${client.label || client.client_id}</p>`;
    html += `<p><strong>Workouts deleted:</strong> ${result.workouts_deleted}</p>`;
    html += `<p><strong>Profile metrics deleted:</strong> ${result.metrics_deleted}</p>`;
    html += `<p><strong>Warnings deleted:</strong> ${result.warnings_deleted}</p>`;
    html += '</div>';
    html += '<div style="margin-top: 20px;">';
    html += '<a href="/ui" class="btn">Back to Clients</a>';
    html += '</div>';
    
    const layoutPath = path.join(__dirname, '../views/layout.html');
    const layout = fs.readFileSync(layoutPath, 'utf8')
        .replace('{{title}}', 'Client Deleted')
        .replace('{{content}}', html);
    res.send(layout);
}));

/**
 * GET /ui/diagnostics/schema
 * Schema diagnostic page - checks database schema
 */
router.get('/diagnostics/schema', asyncHandler(async (req, res) => {
    const pool = require('../db/connection');
    const client = await pool.connect();
    
    let html = '<h2>🔧 Schema Diagnostics</h2>';
    html += '<p style="margin-bottom: 20px;">Checking database schema for potential issues...</p>';
    
    try {
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
        
        html += '<div style="background: #f8f9fa; padding: 20px; border-radius: 8px; margin: 20px 0;">';
        html += '<h3>Workouts Table Schema</h3>';
        html += '<table style="width: 100%; border-collapse: collapse;">';
        html += '<thead><tr style="background: #e9ecef;"><th style="padding: 10px; text-align: left;">Column</th><th style="padding: 10px; text-align: left;">Type</th><th style="padding: 10px; text-align: left;">Nullable</th></tr></thead>';
        html += '<tbody>';
        
        result.rows.forEach(row => {
            const rowStyle = row.column_name === 'duration_seconds' && row.data_type !== 'real' && row.data_type !== 'double precision' 
                ? 'style="background: #fff3cd;"' 
                : '';
            html += `<tr ${rowStyle}>`;
            html += `<td style="padding: 8px; border-bottom: 1px solid #dee2e6;"><strong>${row.column_name}</strong></td>`;
            html += `<td style="padding: 8px; border-bottom: 1px solid #dee2e6;"><code>${row.data_type}</code></td>`;
            html += `<td style="padding: 8px; border-bottom: 1px solid #dee2e6;">${row.is_nullable}</td>`;
            html += `</tr>`;
        });
        
        html += '</tbody></table>';
        html += '</div>';
        
        // Check duration_seconds specifically
        const durationCheck = result.rows.find(r => r.column_name === 'duration_seconds');
        if (durationCheck) {
            html += '<div style="margin: 20px 0;">';
            if (durationCheck.data_type === 'real' || durationCheck.data_type === 'double precision') {
                html += '<div style="background: #d4edda; padding: 15px; border-radius: 8px; border: 1px solid #c3e6cb;">';
                html += '<strong style="color: #155724;">✓ duration_seconds column type is correct</strong>';
                html += `<p style="margin: 5px 0 0 0; color: #155724;">Type: <code>${durationCheck.data_type}</code> - Can accept decimal values</p>`;
                html += '</div>';
            } else {
                html += '<div style="background: #f8d7da; padding: 15px; border-radius: 8px; border: 1px solid #f5c6cb;">';
                html += '<strong style="color: #721c24;">✗ duration_seconds column type is incorrect</strong>';
                html += `<p style="margin: 5px 0 0 0; color: #721c24;">Current type: <code>${durationCheck.data_type}</code> - Should be <code>REAL</code></p>`;
                html += '<p style="margin: 10px 0 0 0; color: #721c24;">Run this SQL to fix: <code style="background: white; padding: 5px; border-radius: 4px;">ALTER TABLE workouts ALTER COLUMN duration_seconds TYPE REAL;</code></p>';
                html += '</div>';
            }
            html += '</div>';
        } else {
            html += '<div style="background: #f8d7da; padding: 15px; border-radius: 8px; border: 1px solid #f5c6cb; margin: 20px 0;">';
            html += '<strong style="color: #721c24;">✗ duration_seconds column not found!</strong>';
            html += '</div>';
        }
        
        // Check sample workout data
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
            html += '<div style="background: #f8f9fa; padding: 20px; border-radius: 8px; margin: 20px 0;">';
            html += '<h3>Sample Workout Durations (Last 5)</h3>';
            html += '<table style="width: 100%; border-collapse: collapse;">';
            html += '<thead><tr style="background: #e9ecef;"><th style="padding: 10px; text-align: left;">ID</th><th style="padding: 10px; text-align: left;">Duration (seconds)</th><th style="padding: 10px; text-align: left;">Type</th><th style="padding: 10px; text-align: left;">Status</th></tr></thead>';
            html += '<tbody>';
            
            sampleResult.rows.forEach(row => {
                const duration = row.duration_seconds;
                const isDecimal = duration != null && duration % 1 !== 0;
                const status = isDecimal ? '✓ Decimal' : 'Integer';
                const statusColor = isDecimal ? '#28a745' : '#ffc107';
                
                html += '<tr>';
                html += `<td style="padding: 8px; border-bottom: 1px solid #dee2e6;">${row.id}</td>`;
                html += `<td style="padding: 8px; border-bottom: 1px solid #dee2e6;"><code>${duration}</code></td>`;
                html += `<td style="padding: 8px; border-bottom: 1px solid #dee2e6;">${row.workout_type}</td>`;
                html += `<td style="padding: 8px; border-bottom: 1px solid #dee2e6;"><span style="color: ${statusColor};">${status}</span></td>`;
                html += '</tr>';
            });
            
            html += '</tbody></table>';
            html += '</div>';
        } else {
            html += '<div style="background: #e7f3ff; padding: 15px; border-radius: 8px; margin: 20px 0;">';
            html += '<p style="margin: 0;">No workouts in database yet. Try syncing from the iOS app to see if they insert successfully.</p>';
            html += '</div>';
        }
        
    } catch (error) {
        html += '<div style="background: #f8d7da; padding: 15px; border-radius: 8px; border: 1px solid #f5c6cb; margin: 20px 0;">';
        html += '<strong style="color: #721c24;">Error checking schema:</strong>';
        html += `<p style="color: #721c24; margin: 5px 0 0 0;"><code>${error.message}</code></p>`;
        html += '</div>';
    } finally {
        client.release();
    }
    
    html += '<div style="margin-top: 30px;">';
    html += '<a href="/ui" class="btn">Back to Clients</a> ';
    html += '<button onclick="location.reload()" class="btn" style="background-color: #6c757d;">🔄 Refresh</button>';
    html += '</div>';
    
    const layoutPath = path.join(__dirname, '../views/layout.html');
    const layout = fs.readFileSync(layoutPath, 'utf8')
        .replace('{{title}}', 'Schema Diagnostics')
        .replace('{{content}}', html);
    res.send(layout);
}));

module.exports = router;
