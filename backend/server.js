//
//  server.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const express = require('express');
const { initializeDatabase } = require('./db/init');
const { testConnection } = require('./db/connection');

// Initialize Express app
const app = express();
const PORT = process.env.PORT || 3001;

// Middleware
app.use(express.json());
app.use(express.urlencoded({ extended: true })); // For form submissions

// Request logging middleware
app.use((req, res, next) => {
    console.log(`[${new Date().toISOString()}] ${req.method} ${req.path}`);
    next();
});

// Health check with DB connectivity (lightweight query)
app.get('/health', async (req, res) => {
    const dbHealthy = await testConnection();
    res.status(dbHealthy ? 200 : 503).json({
        status: dbHealthy ? 'ok' : 'unhealthy',
        database: dbHealthy ? 'connected' : 'disconnected',
        timestamp: new Date().toISOString()
    });
});

// Routes
const ingestRoutes = require('./routes/ingest');
const readRoutes = require('./routes/read');
const pairRoutes = require('./routes/pair');
const clientsRoutes = require('./routes/clients');
const uiRoutes = require('./routes/ui');
const devRoutes = require('./routes/dev');

// Web UI (must come before API routes to avoid conflicts)
app.use('/ui', uiRoutes);

// Dev routes (clearly marked DEV ONLY)
app.use('/dev', devRoutes);

// Direct routes (for manual testing)
app.use('/ingest', ingestRoutes);
app.use('/', readRoutes);
app.use('/pair', pairRoutes);
app.use('/clients', clientsRoutes);

// API v1 routes (for iOS client compatibility)
// Note: Express will match routes in order, so more specific routes first
app.use('/api/v1', ingestRoutes);  // POST /api/v1/workouts, POST /api/v1/profile-metrics
app.use('/api/v1', readRoutes);  // GET /api/v1/workouts, GET /api/v1/profile-metrics, POST /api/v1/workouts/query, POST /api/v1/profile-metrics/query
app.use('/api/v1', pairRoutes);  // POST /api/v1/pair
app.use('/api/v1', clientsRoutes);  // POST /api/v1/clients, GET /api/v1/clients

// Error handling middleware
app.use((err, req, res, next) => {
    if (err instanceof SyntaxError && err.status === 400 && 'body' in err) {
        // JSON parse error
        console.error('[ERROR] Invalid JSON:', err.message);
        return res.status(400).json({
            success: false,
            error: 'Invalid JSON in request body'
        });
    }
    
    console.error('[ERROR] Unhandled error:', err);
    res.status(500).json({
        success: false,
        error: 'Internal server error'
    });
});

// Startup: Initialize DB then start server
async function startServer() {
    try {
        console.log('Connecting to PostgreSQL...');
        await initializeDatabase();
        console.log('Database initialized successfully');
        
        app.listen(PORT, () => {
            console.log(`=================================`);
            console.log(`GymDashSync Backend Server`);
            console.log(`Listening on port ${PORT}`);
            console.log(`=================================`);
            console.log(`🌐 Web UI: http://localhost:${PORT}/ui`);
            console.log(``);
            console.log(`API Endpoints:`);
            console.log(`  Health: GET http://localhost:${PORT}/health`);
            console.log(`  Pair: POST http://localhost:${PORT}/pair`);
            console.log(`  Clients: POST/GET http://localhost:${PORT}/clients`);
            console.log(`  Ingest workouts: POST http://localhost:${PORT}/ingest/workouts`);
            console.log(`  Ingest profile: POST http://localhost:${PORT}/ingest/profile`);
            console.log(``);
            console.log(`Dev Endpoints:`);
            console.log(`  Seed: POST http://localhost:${PORT}/dev/seed`);
            console.log(`  Health: GET http://localhost:${PORT}/dev/health`);
            console.log(`=================================`);
        });
    } catch (error) {
        console.error('Failed to start server:', error);
        process.exit(1);
    }
}

startServer();
