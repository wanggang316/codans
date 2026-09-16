# Codans Product Context

## Register
Product: a native macOS terminal application.

## Users and Purpose
CLI-agent power users manage projects, worktrees, tabs and panes. Terminals remain the primary work surface. Source: docs/product-spec.md and docs/architecture.md.

## Interaction Principles
Use native SwiftUI/AppKit controls, system typography, inherited macOS appearance and accessibility labels. Keep command execution separate from definition editing and historical inspection. Avoid replacing the terminal with a management dashboard after launch.

## Workflow Direction
Workflow settings are a peer of Agents and contain definitions only. Run and history controls form a group before Agents on the main window's right toolbar. History follows Prowl's compact popover and drill-down pattern. Starting a run shows execution feedback; human decisions identify the required action explicitly. No standalone Workflow window or menu-bar menu.

## References
Prowl WorkflowHistoryPopoverButton and WorkflowStepHistoryView; existing Codans WorktreeDetailView toolbar and Settings controls. No new visual theme or image assets are needed for this navigation correction.
