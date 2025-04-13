# LLM Interaction Rules for Documentation ([Project Name])

This document outlines rules for Large Language Models (LLMs) interacting with the [Project Name] codebase, specifically regarding project documentation.

**Goal:** Maintain accurate, up-to-date documentation that reflects the current state of the codebase and project decisions.

## Existing/Expected Documentation Files

Please be aware of the following types of documentation files, typically located in a `/Documentation` or `/docs` directory (adapt paths/names as needed):

*   **`[Architecture Document]`** (e.g., `ProjectStructure.md`, `Architecture.md`): Describes the high-level directory structure, architecture (e.g., MVVM, MVC, VIPER), and potentially lists key components/modules. **Requires updates** when:
    *   Files/directories are added, removed, or significantly refactored.
    *   The overall architecture changes.
    *   Major component connections are altered.
*   **`[Task Tracking File]`** (e.g., `ToDo.md`, `Backlog.md`): Tracks potential improvements, refactoring tasks, technical debt, or items to review. **Requires updates** when:
    *   A listed task is completed.
    *   New technical debt or areas for improvement are identified.
    *   Priorities change.
*   **`[Code Reference Document(s)]`** (e.g., `CodebaseDocumentation.md`, `APIReference.md`, code comments): Detailed documentation of specific classes, functions, modules, or APIs. **Requires updates** when:
    *   The documented code (classes, functions, features, APIs) is significantly changed or removed.
*   **`[Technical Specification Document]`** (e.g., `TechnicalSpecification.md`, `Requirements.md`): Outlines the technical requirements, features, and specifications of the application/library. **Requires updates** when:
    *   Core features are added or significantly changed.
    *   Technical requirements (e.g., supported platforms, dependencies, specific hardware features used) are modified.
*   **`[Changelog]`** (e.g., `CHANGELOG.md`): Logs notable changes for each version. **Requires updates** when:
    *   New features are added.
    *   Bug fixes are implemented.
    *   Significant refactoring or performance improvements occur.
*   **`[Other Reference Materials]`**: (e.g., PDFs, design documents, external links). (Likely no updates needed by LLM).

## LLM Responsibilities

1.  **Consult Documentation:** Before making significant changes or answering questions about structure/architecture, consult the relevant documentation files identified in the project.
2.  **Update Documentation:** After making code changes that impact any of the areas covered by the documentation listed above, **proactively update the relevant markdown file(s)** in the same turn or immediately following the code change. **If a relevant documentation file does not exist (e.g., no Changelog exists when adding a new feature), create it.** Clearly state which documentation files you are updating or creating.
3.  **Maintain Consistency:** Ensure that code changes and documentation updates are consistent with the project's established architecture, coding style, and technical specifications.
4.  **Record Decisions (Optional but Recommended):** For significant architectural or technical decisions made during interaction, consider suggesting the creation or update of an Architecture Decision Record (ADR) in a separate file (e.g., within `/Documentation/ADRs/`).

By following these rules, we can ensure the documentation remains a useful asset for the project's development. 