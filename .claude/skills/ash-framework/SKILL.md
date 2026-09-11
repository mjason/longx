---
name: ash-framework
description: "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

### ash

- [ash](references/ash/ash.md)
- [actions](references/ash/actions.md)
- [aggregates](references/ash/aggregates.md)
- [authorization](references/ash/authorization.md)
- [calculations](references/ash/calculations.md)
- [code_interfaces](references/ash/code_interfaces.md)
- [code_structure](references/ash/code_structure.md)
- [data_layers](references/ash/data_layers.md)
- [exist_expressions](references/ash/exist_expressions.md)
- [generating_code](references/ash/generating_code.md)
- [migrations](references/ash/migrations.md)
- [query_filter](references/ash/query_filter.md)
- [querying_data](references/ash/querying_data.md)
- [relationships](references/ash/relationships.md)
- [testing](references/ash/testing.md)

### ash_phoenix

- [ash_phoenix](references/ash_phoenix/ash_phoenix.md)
- [best_practices](references/ash_phoenix/best_practices.md)
- [debugging_form_submissions](references/ash_phoenix/debugging_form_submissions.md)
- [error_handling](references/ash_phoenix/error_handling.md)
- [form_integration](references/ash_phoenix/form_integration.md)
- [nested_forms](references/ash_phoenix/nested_forms.md)
- [union_forms](references/ash_phoenix/union_forms.md)

### ash_typescript

- [ash_typescript](references/ash_typescript/ash_typescript.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p ash -p ash_cloak -p ash_phoenix -p ash_sqlite -p ash_typescript
```

## Available Mix Tasks

- `mix ash` - Prints Ash help information
- `mix ash.codegen` - Runs all codegen tasks for any extension on any resource/domain in your application.
- `mix ash.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.gen.base_resource` - Generates a base resource. This is a module that you can use instead of `Ash.Resource`, for consistency.
- `mix ash.gen.change` - Generates a custom change module.
- `mix ash.gen.custom_expression` - Generates a custom expression module.
- `mix ash.gen.domain` - Generates an Ash.Domain
- `mix ash.gen.enum` - Generates an Ash.Type.Enum
- `mix ash.gen.gettext` - Copies Ash's .pot file for error message translation
- `mix ash.gen.preparation` - Generates a custom preparation module.
- `mix ash.gen.resource` - Generate and configure an Ash.Resource.
- `mix ash.gen.validation` - Generates a custom validation module.
- `mix ash.generate_livebook` - Generates a Livebook for each Ash domain
- `mix ash.generate_policy_charts` - Generates a Mermaid Flow Chart for a given resource's policies.
- `mix ash.generate_resource_diagrams` - Generates Mermaid Resource Diagrams for each Ash domain
- `mix ash.gettext.extract` - Extracts Ash error messages into a .pot file
- `mix ash.install` - Installs Ash into a project. Should be called with `mix igniter.install ash`
- `mix ash.manifest.dump` - Dump the Ash app manifest as JSON
- `mix ash.migrate` - Runs all migration tasks for any extension on any resource/domain in your application.
- `mix ash.patch.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.reset` - Runs all tear down & setup tasks for any extension on any resource/domain in your application.
- `mix ash.rollback` - Runs all rollback tasks for any extension on any resource/domain in your application.
- `mix ash.set.domains` - Dynamically discovers and updates Ash domains in config.exs
- `mix ash.setup` - Runs all setup tasks for any extension on any resource/domain in your application.
- `mix ash.tear_down` - Runs all tear_down tasks for any extension on any resource/domain in your application.
- `mix ash_phoenix.gen.html` - Generates a controller and HTML views for an existing Ash resource.
- `mix ash_phoenix.gen.live` - Generates liveviews for a given domain and resource.
- `mix ash_phoenix.install` - Installs AshPhoenix into a project. Should be called with `mix igniter.install ash_phoenix`
- `mix ash_sqlite.create` - Creates the repository storage
- `mix ash_sqlite.drop` - Drops the repository storage for the repos in the specified (or configured) domains
- `mix ash_sqlite.generate_migrations` - Generates migrations, and stores a snapshot of your resources
- `mix ash_sqlite.install` - Installs AshSqlite. Should be run with `mix igniter.install ash_sqlite`
- `mix ash_sqlite.migrate` - Runs the repository migrations for all repositories in the provided (or configured) domains
- `mix ash_sqlite.rollback` - Rolls back the repository migrations for all repositories in the provided (or configured) domains
- `mix ash_typescript.codegen` - Generates TypeScript types for Ash Rpc-calls
- `mix ash_typescript.install` - Installs AshTypescript into a project. Should be called with `mix igniter.install ash_typescript`
- `mix ash_typescript.npm_install`
<!-- usage-rules-skill-end -->
