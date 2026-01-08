//
//  asyncHandler.js
//  GymDashSync Backend
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

/**
 * Wraps async route handlers to catch errors and pass to Express error middleware
 * Usage: router.post('/path', asyncHandler(async (req, res) => { ... }))
 */
function asyncHandler(fn) {
  return (req, res, next) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
}

module.exports = asyncHandler;

