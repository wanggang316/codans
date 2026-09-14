# Design Doc: [Title]

**Availability:** Available | Hidden | Planned (specify scope for mixed features)
**Document Status:** Draft | Approved
**Author:** [name]
**Date:** [date]
**Last Reviewed:** [date; source wiring, runtime, or both]
**Implementation:** [relative links to entry points, or none for a planned feature]

## Context and Scope

<!-- Objective background facts. Rough overview of the landscape: what
     is being built or changed, and what already exists. Keep succinct —
     bring readers up to speed without restating what they already know. -->

## Goals and Non-Goals

<!-- Short bullet-point lists.
     Goals: what the system must achieve.
     Non-Goals: things that could reasonably be goals but are
     intentionally excluded. Not negated goals ("shouldn't crash")
     but deliberate scope cuts ("ACID compliance is not a goal"). -->

## Design

### Overview

<!-- High-level summary of the chosen approach. Start here so readers
     can decide how deep to go. Explain WHY this approach best satisfies
     the stated goals — this is where trade-offs live. -->

### System Context Diagram

<!-- How does this system fit in the larger technical landscape?
     Show the system as a box within its surrounding environment —
     external systems, users, data flows in and out. This lets readers
     contextualize the design within what they already know.

     Use ASCII diagrams:
     ┌─────────┐     ┌─────────┐     ┌──────────┐
     │  Client  │────→│   API   │────→│ Database │
     └─────────┘     └─────────┘     └──────────┘  -->

### API Design

<!-- Sketch the APIs this system exposes or consumes. Focus on the parts
     relevant to design trade-offs — do NOT copy-paste formal interface
     definitions (verbose, unnecessary detail, quickly outdated).

     Show: endpoints/methods, key parameters, response shapes,
     error handling approach. -->

### Data Storage

<!-- How and in what form is data stored? Focus on trade-off relevant
     portions, not complete schema definitions.

     Cover: storage technology choice and why, key entities and
     relationships, access patterns, migration strategy if applicable. -->

### Component Boundaries

<!-- Internal structure: what are the components, what is each
     responsible for, and what is each NOT responsible for?

     Define dependency directions (who can import from whom),
     communication patterns (APIs, events, shared types),
     and module boundaries. -->

## Alternatives Considered

<!-- For each alternative: what trade-offs does it make, and how do
     those trade-offs compare to the chosen design? Be thorough about
     WHY alternatives were rejected — this is what prevents
     re-litigating the decision later.

     Every rejected alternative needs a concrete reason,
     not just "it didn't feel right." -->

## Cross-Cutting Concerns

<!-- How does this design address concerns that span the system:
     security, privacy, observability, error handling, testing strategy,
     migration path, rollback plan.
     Only include concerns relevant to this design. -->

## Risks

<!-- What could go wrong? Each risk needs a mitigation strategy,
     not just a worry. -->
