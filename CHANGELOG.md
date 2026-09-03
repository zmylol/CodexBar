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
- Exact Codex desktop thread opening with per-task client routing.
- Source build, isolated tests, install, Hook migration, and uninstall scripts.

### Fixed

- Open tasks created in Codex Desktop in their matching desktop thread instead of reporting a missing VS Code window.
- Reconcile exact active VS Code and terminal CLI turns with the official App Server so a manually interrupted turn cannot remain stuck in running or attention state when Codex omits its `Stop` Hook.
- Persist bounded deletion tombstones so startup recovery cannot resurrect a user-deleted task.
- Mark real-time recovered terminal states unread and announce that they are ready to view.

### Security

- Private local file permissions and bounded Hook/App Server input.
- Exact executable matching when managing CodexBar Hook handlers.
- Bounded local archive and installer backup retention.
- Microsoft Team signature verification before VS Code window discovery and activation.
- OpenAI Team signature verification before dispatching Codex desktop thread links.
- Fail-closed symlink validation for runtime storage, Hook installation, and uninstall paths.
- Background Inbox and task-storage actors with batched persistence, revision-safe publication, and archive retention.
