//
//  validation.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

const { clientExists } = require('./queries');

/**
 * Validation result
 */
class ValidationResult {
    constructor() {
        this.errors = [];
        this.warnings = [];
        this.isValid = true;
    }
    
    addError(message) {
        this.errors.push(message);
        this.isValid = false;
    }
    
    addWarning(message) {
        this.warnings.push(message);
    }
    
    hasIssues() {
        return this.errors.length > 0 || this.warnings.length > 0;
    }
}

/**
 * Validate workout record
 */
function validateWorkout(workout, clientId) {
    const result = new ValidationResult();
    
    // Required fields
    if (!workout.workout_type) {
        result.addError('workout_type is required');
    }
    
    if (!workout.start_time) {
        result.addError('start_time is required');
    }
    
    if (!workout.end_time) {
        result.addError('end_time is required');
    }
    
    if (workout.duration_seconds === undefined || workout.duration_seconds === null) {
        result.addError('duration_seconds is required');
    }
    
    // Validate timestamps
    if (workout.start_time && workout.end_time) {
        try {
            const start = new Date(workout.start_time);
            const end = new Date(workout.end_time);
            
            if (isNaN(start.getTime())) {
                result.addError('start_time must be valid ISO8601');
            }
            
            if (isNaN(end.getTime())) {
                result.addError('end_time must be valid ISO8601');
            }
            
            if (!isNaN(start.getTime()) && !isNaN(end.getTime())) {
                // Check start < end
                if (start >= end) {
                    result.addError('start_time must be before end_time');
                }
                
                // Check duration matches time delta (±10% tolerance)
                const actualDuration = (end - start) / 1000; // seconds
                const reportedDuration = workout.duration_seconds;
                const tolerance = actualDuration * 0.1;
                
                if (Math.abs(actualDuration - reportedDuration) > tolerance) {
                    result.addWarning(`Duration mismatch: reported ${reportedDuration}s, calculated ${actualDuration.toFixed(1)}s`);
                }
            }
        } catch (e) {
            result.addError(`Invalid timestamp format: ${e.message}`);
        }
    }
    
    // Validate workout_type
    const validTypes = ['run', 'walk', 'cycle', 'strength', 'hiit', 'other'];
    if (workout.workout_type && !validTypes.includes(workout.workout_type)) {
        result.addWarning(`Unknown workout_type: ${workout.workout_type}, mapping to 'other'`);
        workout.workout_type = 'other';
    }
    
    // Validate numeric fields
    if (workout.duration_seconds !== undefined && workout.duration_seconds !== null) {
        if (typeof workout.duration_seconds !== 'number' || workout.duration_seconds < 0) {
            result.addError('duration_seconds must be a non-negative number');
        }
    }
    
    if (workout.calories_active !== undefined && workout.calories_active !== null) {
        if (typeof workout.calories_active !== 'number' || workout.calories_active < 0) {
            result.addWarning('calories_active should be non-negative');
        }
    }
    
    if (workout.distance_meters !== undefined && workout.distance_meters !== null) {
        if (typeof workout.distance_meters !== 'number' || workout.distance_meters < 0) {
            result.addWarning('distance_meters should be non-negative');
        }
    }
    
    if (workout.avg_heart_rate !== undefined && workout.avg_heart_rate !== null) {
        if (typeof workout.avg_heart_rate !== 'number' || workout.avg_heart_rate < 0 || workout.avg_heart_rate > 300) {
            result.addWarning('avg_heart_rate seems unusual');
        }
    }
    
    // Validate client_id matches
    if (workout.client_id !== clientId) {
        result.addError(`client_id mismatch: expected ${clientId}, got ${workout.client_id}`);
    }
    
    return result;
}

/**
 * Validate profile metric record
 */
function validateProfileMetric(metric, clientId) {
    const result = new ValidationResult();
    
    // Required fields
    if (!metric.metric) {
        result.addError('metric is required');
    }
    
    if (metric.value === undefined || metric.value === null) {
        result.addError('value is required');
    }
    
    if (!metric.unit) {
        result.addError('unit is required');
    }
    
    if (!metric.measured_at) {
        result.addError('measured_at is required');
    }
    
    // Validate metric type
    const validMetrics = ['height', 'weight', 'body_fat'];
    if (metric.metric && !validMetrics.includes(metric.metric)) {
        result.addWarning(`Unknown metric type: ${metric.metric}`);
    }
    
    // Validate value
    if (metric.value !== undefined && metric.value !== null) {
        if (typeof metric.value !== 'number') {
            result.addError('value must be a number');
        } else {
            // Reasonable bounds
            if (metric.metric === 'height' && (metric.value < 50 || metric.value > 300)) {
                result.addWarning('height value seems unusual (expected cm)');
            }
            if (metric.metric === 'weight' && (metric.value < 20 || metric.value > 300)) {
                result.addWarning('weight value seems unusual (expected kg)');
            }
            if (metric.metric === 'body_fat' && (metric.value < 0 || metric.value > 100)) {
                result.addWarning('body_fat value seems unusual (expected percent)');
            }
        }
    }
    
    // Validate timestamp
    if (metric.measured_at) {
        try {
            const date = new Date(metric.measured_at);
            if (isNaN(date.getTime())) {
                result.addError('measured_at must be valid ISO8601');
            }
        } catch (e) {
            result.addError(`Invalid timestamp format: ${e.message}`);
        }
    }
    
    // Validate client_id matches
    if (metric.client_id !== clientId) {
        result.addError(`client_id mismatch: expected ${clientId}, got ${metric.client_id}`);
    }
    
    return result;
}

/**
 * Check if client_id exists
 */
function validateClientId(clientId) {
    if (!clientId) {
        return { valid: false, error: 'client_id is required' };
    }
    
    if (!clientExists(clientId)) {
        return { valid: false, error: `client_id does not exist: ${clientId}` };
    }
    
    return { valid: true };
}

module.exports = {
    ValidationResult,
    validateWorkout,
    validateProfileMetric,
    validateClientId
};

