//
//  ui.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const express = require('express');
const router = express.Router();
const { 
    getAllClientsWithStats, 
    getClientById,
    getWorkoutsByClientId,
    getProfileMetricsByClientId,
    getWarningsByClientId
} = require('../db/queries');
const { createClient } = require('../db/queries');

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
router.get('/', (req, res) => {
    try {
        const clients = getAllClientsWithStats();
        
        let html = '<h2>Clients</h2>';
        html += '<a href="/ui/clients/new" class="btn">Create New Client</a>';
        
        if (clients.length === 0) {
            html += '<p style="margin-top: 20px;">No clients yet. Create your first client to get started.</p>';
        } else {
            html += '<table>';
            html += '<thead><tr><th>Label</th><th>Client ID</th><th>Pairing Code</th><th>Workouts</th><th>Last Workout</th><th>Warnings</th><th>Action</th></tr></thead>';
            html += '<tbody>';
            
            for (const client of clients) {
                const warningsBadge = client.warnings_count > 0 
                    ? `<span class="warning">⚠️ ${client.warnings_count}</span>` 
                    : '0';
                
                html += `<tr>`;
                html += `<td>${client.label || '<em>No label</em>'}</td>`;
                html += `<td><span class="code">${client.client_id.substring(0, 8)}...</span></td>`;
                html += `<td><span class="code">${client.pairing_code}</span></td>`;
                html += `<td>${client.workouts_count || 0}</td>`;
                html += `<td>${formatDate(client.last_workout_start_time)}</td>`;
                html += `<td>${warningsBadge}</td>`;
                html += `<td><a href="/ui/clients/${client.client_id}" class="btn btn-secondary">View</a></td>`;
                html += `</tr>`;
            }
            
            html += '</tbody></table>';
        }
        
        const layoutPath = path.join(__dirname, '../views/layout.html');
        const layout = fs.readFileSync(layoutPath, 'utf8')
            .replace('{{title}}', 'Clients')
            .replace('{{content}}', html);
        res.send(layout);
        
    } catch (error) {
        console.error('[UI] Clients list error:', error);
        res.status(500).send(`<h2>Error</h2><p>${error.message}</p>`);
    }
});

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
router.post('/clients', (req, res) => {
    try {
        const { label } = req.body;
        
        const clientId = generateUUID();
        let pairingCode = generatePairingCode();
        
        // Ensure uniqueness
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
        
    } catch (error) {
        console.error('[UI] Create client error:', error);
        res.status(500).send(`<h2>Error</h2><p>${error.message}</p>`);
    }
});

/**
 * GET /ui/clients/:client_id
 * Client detail page
 */
router.get('/clients/:client_id', (req, res) => {
    try {
        const { client_id } = req.params;
        const client = getClientById(client_id);
        
        if (!client) {
            return res.status(404).send('<h2>Client Not Found</h2><p><a href="/ui">Back to Clients</a></p>');
        }
        
        const workouts = getWorkoutsByClientId(client_id, 50);
        const metrics = getProfileMetricsByClientId(client_id, 50);
        const warnings = getWarningsByClientId(client_id, 50);
        
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
        
        html += '<div style="margin-top: 30px;">';
        html += '<a href="/ui" class="btn">Back to Clients</a>';
        html += '</div>';
        
        const layoutPath = path.join(__dirname, '../views/layout.html');
        const layout = fs.readFileSync(layoutPath, 'utf8')
            .replace('{{title}}', client.label || 'Client')
            .replace('{{content}}', html);
        res.send(layout);
        
    } catch (error) {
        console.error('[UI] Client detail error:', error);
        res.status(500).send(`<h2>Error</h2><p>${error.message}</p>`);
    }
});

module.exports = router;

