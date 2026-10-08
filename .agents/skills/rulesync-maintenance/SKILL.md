---
name: rulesync-maintenance
description: >-
  Maintain this repository's rulesync configuration, AGENTS.md guidance, and
  agent skills. Use when editing .rulesync sources, adding skills or targets,
  regenerating outputs, or checking generated-file drift.
---
# Rulesync maintenance

## Ownership

- `rulesync.jsonc` selects project outputs: `agentsmd` for root guidance and `agentsskills` for portable skills.
- `.rulesync/rules/overview.md` is the canonical root rule, with `root: true` YAML frontmatter.
- `.rulesync/skills/<name>/SKILL.md` is each canonical skill, with `name`, a task-triggering `description`, and `targets` YAML frontmatter. Match the lowercase kebab-case name to its directory.
- `AGENTS.md` and `.agents/skills/` are generated and committed so a fresh checkout contains usable guidance. Edit sources, not generated copies.

## Change and generate

1. Read the current configuration and the affected source. Check repository docs and code before adding commands or invariants; avoid copying time-sensitive artifact measurements into guidance.
2. Keep always-on guidance short. Put task procedures in skills and link each skill from the root rule. Reuse `CONTRIBUTING.md` as the submission contract rather than maintaining another schema specification.
3. Add only targets and features required by the workflow. Do not enable wildcard output, MCP servers, automatic command hooks, or tool permissions incidentally.
4. Generate with the pinned CLI from the repository root (Node.js 22 or later):

   ```sh
   npx --yes rulesync@27.0.0 generate
   npx --yes rulesync@27.0.0 generate --check
   ```

5. Inspect the resulting guidance and skills for correct paths, valid frontmatter, and absence of secrets or fabricated evidence. Commit canonical sources and generated outputs together.

Deletion is disabled in the project config to avoid sweeping directories that may contain unrelated agent configuration. If a source is removed or renamed, identify and remove its now-obsolete generated file explicitly; do not use broad `--delete` without checking ownership. Do not run `rulesync gitignore`: this repository intentionally commits the generated guidance and skills. Personal overrides belong in ignored `rulesync.local.jsonc`.

When upgrading rulesync, update the pinned command everywhere it is documented and the schema URL in `rulesync.jsonc`, then generate and run `--check`. Consult the official configuration and file-format references for version-specific changes:

- https://rulesync.dyoshikawa.com/guide/configuration
- https://rulesync.dyoshikawa.com/reference/file-formats
