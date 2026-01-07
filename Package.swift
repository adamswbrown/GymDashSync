// swift-tools-version:5.5
// Package.swift
// GymDashSync
//
// Copyright (c) 2024
// Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "GymDashSync",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "HealthDataSync",
            targets: ["HealthDataSync"]),
        .library(
            name: "GymDashSyncApp",
            targets: ["GymDashSyncApp"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "HealthDataSync",
            path: "HealthDataSync/Sources",
            exclude: []),
        .target(
            name: "GymDashSyncApp",
            dependencies: ["HealthDataSync"],
            path: "GymDashSyncApp/Sources",
            exclude: []),
    ]
)

