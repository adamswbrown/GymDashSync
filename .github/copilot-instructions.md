# GitHub Copilot Agent Instructions for iOS Integration (GymDashSync)

## Purpose
This document provides guidance for GitHub Copilot agents (and human collaborators) working on the integration between the GymDashSync iOS app and the CoachFit backend. Follow these instructions to ensure smooth, reliable, and maintainable integration. These instructions are optimized for Copilot workflows and automation.

---

## 1. API Contract
- Always refer to the latest API documentation in the CoachFit repo (`Web/docs/misc/IOS_APP_INTEGRATION_PLAN.md`).
- When generating code, Copilot should use the documented endpoints, authentication, and data formats.
- Validate responses and handle errors gracefully in generated code.

## 2. Data Sync
- Use HealthKit to collect health metrics (weight, height, workouts, steps, sleep).
- Generate code to sync data via HTTP to CoachFit API endpoints as specified in the integration plan.
- Implement retry logic for failed syncs and log errors for review. Copilot should suggest robust error handling and logging.

## 3. Manual Entry
- Preserve manual entry options for subjective metrics (sleep quality, perceived effort, notes).
- Ensure manual and automatic data are merged correctly in the backend. Copilot should prompt for merge logic if not present.

## 4. Testing & Validation
- Generate integration tests for API requests and responses.
- Test HealthKit data extraction and transformation logic.
- Validate that synced data appears correctly in the CoachFit dashboard. Copilot should suggest test cases and validation steps.

## 5. Documentation & Communication
- Update this document and related integration docs with any changes. Copilot should prompt for documentation updates when code changes affect integration.
- Communicate API changes or integration blockers to both backend and iOS teams.
- Use shared documentation platforms for cross-team visibility.

## 6. Security & Privacy
- Ensure all health data is transmitted securely (HTTPS, authentication tokens). Copilot should always suggest secure defaults.
- Follow privacy best practices for handling user health data.

## 7. Versioning & Updates
- Track API version compatibility and update the app as needed. Copilot should flag deprecated endpoints and suggest migration steps.
- Document any breaking changes and migration steps.

---

## References
- CoachFit Integration Plan: `/Users/adambrown/Developer/CoachFit/Web/docs/misc/IOS_APP_INTEGRATION_PLAN.md`
- HealthKit Documentation: [Apple HealthKit](https://developer.apple.com/documentation/healthkit)
- GymDashSync Backend: `/Users/adambrown/Developer/GymDashSync/backend/`

---

_Last updated: 2026-01-15_
