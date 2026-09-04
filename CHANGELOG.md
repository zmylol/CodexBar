# Changelog

All notable changes to CodexBar will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions use semantic versioning once public releases begin.

## Unreleased

### Added

- Compact always-on-top project bar with hover details.
- Codex Hook ingestion for running, attention, and ready states.
- Transient live hover previews with up to three sanitized activity nodes for the current task.
- Conservative startup recovery from the official Codex App Server.
- Existing-window activation with ambiguity-safe matching.
- Source build, isolated tests, install, Hook migration, and uninstall scripts.

### Changed

- Scope Hook ingestion, startup recovery, task persistence, and window activation exclusively to the official VS Code Codex Extension.
- Migrate legacy task state to a VS Code-only v2 snapshot and discard queued events without a proven VS Code source.

### Fixed

- Persist bounded deletion tombstones so startup recovery cannot resurrect a user-deleted task.

### Security

- Private local file permissions and bounded Hook/App Server input.
- Exact executable matching when managing CodexBar Hook handlers.
- Bounded local archive and installer backup retention.
- Microsoft Team signature verification before VS Code window discovery and activation.
- Exact VS Code originator gating before Hook stdin is read or persisted.
- Fail-closed symlink validation for runtime storage, Hook installation, and uninstall paths.
- Background Inbox and task-storage actors with batched persistence, revision-safe publication, and archive retention.
