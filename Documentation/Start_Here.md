# LLM Interaction Rules for Documentation

This document outlines rules for Large Language Models (LLMs) interacting with the Spencer's Camera codebase, specifically regarding project documentation.

**Goal:** Maintain accurate, up-to-date documentation that reflects the current state of the codebase and project decisions.

## Existing Documentation Files

Please be aware of the following documentation files located in the `/Documentation` directory:

*   **`ProjectStructure.md`**: Describes the high-level directory structure, architecture (MVVM), and contains a list of key files with their descriptions. **Requires updates** when:
    *   Files/directories are added, removed, or significantly refactored.
    *   The overall architecture changes.
    *   Major component connections are altered.
*   **`ToDo.md`**: Tracks potential improvements, refactoring tasks, and items to review. **Requires updates** when:
    *   A listed task is completed.
    *   New technical debt or areas for improvement are identified during development.
    *   Priorities change.
*   **`CodebaseDocumentation.md`**: A more detailed, potentially generated or manually written documentation of specific classes, functions, or features. (Review this file's current content and update its description here if needed).
*   **`TechnicalSpecification.md`**: Outlines the technical requirements, features, and specifications of the application. **Requires updates** when:
    *   Core features are added or significantly changed.
    *   Technical requirements (e.g., supported iOS versions, specific hardware features used) are modified.
*   **`Apple_Log_Profile_White_Paper.pdf`**: Reference material (Likely no updates needed by LLM).

## LLM Responsibilities

1.  **Consult Documentation:** Before making significant changes or answering questions about structure/architecture, consult the relevant documentation files.
2.  **Update Documentation:** After making code changes that impact any of the areas covered by the documentation listed above (especially `ProjectStructure.md` and `ToDo.md`), **proactively update the relevant markdown file(s)** in the same turn or immediately following the code change.
3.  **Maintain Consistency:** Ensure that code changes and documentation updates are consistent with the project's established architecture (MVVM), coding style (Swift/SwiftUI best practices), and technical specifications.
4.  **Record Decisions (Optional but Recommended):** For significant architectural or technical decisions made during interaction, consider suggesting the creation or update of an Architecture Decision Record (ADR) in a separate file within `/Documentation/ADRs/`.

By following these rules, we can ensure the documentation remains a useful asset for the project's development. 