# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.1.0] - 2026-01-12

### Changed
- The action is now using a pre-build image hosted on DockerHub in order to enable the usage of kubernetes mode for self-hosted runners
- The image now uses a non-root user

## [2.0.12] - 2025-06-24

### Added
- Fixed the JWT token issue

## [2.0.11] - 2025-06-17

### Added
- Fixed a changelog issue in telemetry header preparation

## [2.0.10] - 2025-06-06

### Added
- Addressed issue in preparing telemetry header

## [2.0.9] - 2025-06-05

### Added
- Fix the telemetry header issue.

## [2.0.8] - 2025-05-30

### Added
- Automated tests for Edge
- Added unit tests.

## [2.0.7] - 2025-03-24

### Added
- Automated tests for OSS, EP, and Cloud
- Telemetry headers integration

## [2.0.6] - 2024-02-16

### Security
- Updated Alpine base image

## [2.0.5] - 2023-04-20

### Added
- Initial release

[Unreleased]: https://github.com/cyberark/conjur-action/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/cyberark/conjur-action/compare/v2.0.12...v3.0.0
[2.0.12]: https://github.com/cyberark/conjur-action/compare/v2.0.11...v2.0.12
[2.0.11]: https://github.com/cyberark/conjur-action/compare/v2.0.10...v2.0.11
[2.0.10]: https://github.com/cyberark/conjur-action/compare/v2.0.9...v2.0.10
[2.0.9]: https://github.com/cyberark/conjur-action/compare/v2.0.8...v2.0.9
[2.0.8]: https://github.com/cyberark/conjur-action/compare/v2.0.7...v2.0.8
[2.0.7]: https://github.com/cyberark/conjur-action/compare/v2.0.6...v2.0.7
[2.0.6]: https://github.com/cyberark/conjur-action/compare/v2.0.5...v2.0.6
[2.0.5]: https://github.com/cyberark/conjur-action/releases/tag/v2.0.5
