# dbt-sigma-data-models

Compose [Sigma data models](https://help.sigmacomputing.com/docs/manage-data-models-as-code) from a handful of macros instead of hand-writing the full Sigma JSON spec. The compiled spec is attached to a dbt model's `meta` config, so it lands directly in `manifest.json` on `dbt parse` / `dbt compile`. Nothing about the underlying tables is ever touched; a warehouse connection is only needed if you lean on `sigma_data_models.table()`'s column auto-population (see below) — with explicit `columns`, `dbt parse` alone is enough.

The compiled shape follows Sigma's own documented [data model representation examples](https://help.sigmacomputing.com/docs/data-model-representation-example-library) as closely as this package's scope allows — see [Coverage](#coverage) for exactly what's modeled and what isn't, and `integration_tests/README.md` for which specific example each shape is checked against.

<img width="1540" height="549" alt="Screenshot 2026-07-29 at 10 47 53 PM" src="https://github.com/user-attachments/assets/3b844ee4-cede-4f25-8143-56746ff3cc2c" />


## Adapter support

All dbt adapters are supported. This package is purely compile-time JSON composition — the macros emit Sigma's spec into `config(meta=...)` with no adapter-specific SQL. A warehouse connection is only needed when `columns` are omitted from `sigma_data_models.table()` (column auto-population via `adapter.get_columns_in_relation`); with explicit `columns`, `dbt parse` alone is sufficient.

## Installation

Add to your `packages.yml`:

```yaml
packages:
  - package: Matts52/sigma_data_models
    version: 1.0.2
```

Then run `dbt deps`.

## Usage

Define one dbt model per Sigma data model. The model's only job is to carry the compiled spec in its config; give it a trivial `select` body and a non-materializing config:

```sql
-- models/sigma_territory_carving.sql
{% set sigma_data_model = sigma_data_models.model(
    name='Territory Carving',
    tables=[
      sigma_data_models.table('accounts', 'stg_accounts',
        columns=['account_guid', 'account_name', 'account_owner_user_guid'],
        metrics={'count_accounts': 'CountDistinct([Account Guid])'}),
      sigma_data_models.table('employees', 'stg_employees',
        columns=['employee_guid', 'employee_name']),
    ],
    relationships=[
      ('accounts', 'account_owner_user_guid', 'employees', 'employee_guid'),
    ],
) %}

{{ sigma_data_models.materialize(sigma_data_model) }}

select 1
```

Run `dbt parse` (or `dbt compile`) and the fully composed Sigma JSON is available at `manifest.json -> nodes -> model.<project>.sigma_territory_carving -> config.meta.sigma_data_model`.

`sigma_data_models.materialize()` sets `meta` via `config(meta=...)`, which replaces `meta` wholesale rather than merging it — if the model (or a `+meta:` in `dbt_project.yml`) sets other `meta` keys elsewhere, calling `materialize()` will drop them. Keep these models single-purpose, as shown above, and set any other `meta` you need on a different model.

Pair it with an `exposures:` entry to get native dbt selection over everything the data model depends on:

```yaml
exposures:
  - name: territory_carving
    type: analysis
    depends_on:
      - ref('stg_accounts')
      - ref('stg_employees')
      - ref('sigma_territory_carving')
```

`dbt list -s +exposure:territory_carving` then resolves the full upstream lineage feeding the data model.

## Macros

### sigma_data_models.model
([source](macros/sigma/model.sql))

Top-level data model — assembles one or more tables into a single Sigma page and resolves any declared relationships into their final nested shape.

**Args:**

- `name` (required): Display name for the data model.
- `tables` (required): List of `sigma_data_models.table()` calls to include on the page.
- `relationships` (optional): List of relationship descriptors — either bare `(from, from_column, to, to_column)` tuples or `sigma_data_models.relationship()` calls. Default is `[]`.
- `controls` (optional): List of `sigma_data_models.control()` calls. Default is `[]`.
- `page_name` (optional): Display name for the page. Default is `none`.
- `folder_id` (optional): Sigma folder id to publish into. Defaults to the `sigma_folder_id` project var.
- `data_model_id` (optional): Sigma-assigned data model id for targeting an update instead of a create. Default is `none` — omit until you have the id from a first-time sync.
- `connection_tags` (optional): Version tags that swap the warehouse connection. See [Connection tags](#connection-tags). Default is `[]`.

`key` must be unique across all entries in `tables` — it's what `relationships` resolves `from`/`to` against, so a duplicate is genuinely ambiguous and raises a compiler error.

**Usage:**

```sql
{% set spec = sigma_data_models.model(
    name='Territory Carving',
    tables=[
      sigma_data_models.table('accounts', 'stg_accounts', columns=['account_guid', 'account_name', 'account_industry']),
      sigma_data_models.table('employees', 'stg_employees', columns=['employee_guid', 'employee_name']),
    ],
    relationships=[
      ('accounts', 'account_owner_user_guid', 'employees', 'employee_guid'),
    ],
    controls=[
      sigma_data_models.control('industry_filter', type='value-list',
        targets=[('accounts', 'account_industry')], display_name='Industry'),
    ],
) %}
```

---

### sigma_data_models.control
([source](macros/sigma/control.sql))

A page-level interactive filter element. Controls are siblings to table elements in `pages[].elements[]` — they're not nested inside a table. Each control targets one or more `(table_key, column_name)` pairs (resolved to real element/column ids at compile time) and lets workbook viewers filter those columns interactively.

`name` becomes the `controlId` in the emitted spec — the stable identifier used to reference the control in Sigma formulas. `type` is passed verbatim as `controlType` (e.g. `'value-list'`, `'text'`, `'checkbox'`, `'switch'`, `'date-range'`, `'number-range'`). Control names must be unique within a model; a duplicate raises a compiler error. Each target table key and column name must be an actual key/column in the model; any mismatch raises a compiler error.

> **Note on `controlId` uniqueness:** this package enforces uniqueness within a single `sigma_data_models.model()` call, but Sigma resolves `controlId` globally within a data model (and potentially across models in the same org) when evaluating formula references. Reusing the same `name` on controls in separate data models may cause formula ambiguity in Sigma — use names that are unique to the data model, not just unique within one `model()` call.

**Args:**

- `name` (required): Control key, used as `controlId` and to freeze its id. Lowercased. Must be unique within the model.
- `type` (required): Sigma control type, passed verbatim as `controlType`.
- `targets` (required): List of `(table_key, column_name)` tuples — each pair resolves to a `{source.elementId, columnId}` filter entry. Must be non-empty.
- `display_name` (optional): Display name shown in Sigma. Default derives from `name` via `titleize`.
- `page` (optional): Page to place the control on. Defaults to the page of the first target table.
- `options` (optional): Control-type-specific fields passed through verbatim using Sigma's own field names (e.g. `{'mode': 'equals'}` for a text control). Cannot set `id`, `controlId`, `controlType`, `kind`, or `filters` — those are derived from the other args and attempting to override them raises a compiler error. Default is `{}`.

**Usage:**

```sql
controls=[
  -- single target
  sigma_data_models.control('industry_filter', type='value-list',
    targets=[('accounts', 'account_industry')], display_name='Industry'),

  -- multi-target: same control drives two tables
  sigma_data_models.control('segment_filter', type='value-list',
    targets=[('accounts', 'account_segment'), ('leads', 'lead_segment')]),
]
```

---

### sigma_data_models.table
([source](macros/sigma/table.sql))

A Sigma table element bound to a warehouse relation. Freezes deterministic ids for itself and all of its columns, metrics, folders, and filters.

**Args:**

- `key` (required): Unique name for this table within the model — used to resolve relationships and as the default `identifier`.
- `identifier` (optional): The dbt model name (or warehouse table name) to bind to. Positional — `sigma_data_models.table('accounts', 'stg_accounts', ...)` works without spelling out `identifier=`. Defaults to `key`.
- `database` (optional): Database override. Defaults to the current target database.
- `schema` (optional): Schema override. Defaults to the current target schema.
- `connection_id` (optional): Sigma connection id for this table. Defaults to the `sigma_connection_id` project var.
- `columns` (optional): List of column descriptors — bare strings or `sigma_data_models.column()` calls. Default is `[]`.
- `metrics` (optional): List of metric descriptors — plain `{name: formula}` dicts or `sigma_data_models.metric()` calls. Default is `[]`.
- `folders` (optional): List of `sigma_data_models.folder()` calls. Default is `[]`.
- `filters` (optional): List of `sigma_data_models.filter()` calls. Default is `[]`.

Leaving `columns` off entirely (rather than passing an empty list) auto-populates every column as a passthrough from the live warehouse relation via `adapter.get_columns_in_relation`. This requires a real connection and only works under `dbt run`/`dbt compile` — under `dbt parse`, a table with no explicit `columns` raises a compiler error rather than silently compiling to zero columns. Pass `columns` explicitly to keep a model `dbt parse`-able without a connection.

`metrics`/`folders`/`filters` are omitted from the emitted table when empty, matching Sigma's own representations, which never show empty arrays for these fields.

**Usage:**

```sql
sigma_data_models.table(
    'accounts',
    'stg_accounts',
    columns=['account_guid', 'account_name'],
    metrics={'count_accounts': 'CountDistinct([Account Guid])'},
    folders=[sigma_data_models.folder('Identifiers', columns=['account_guid'])],
    filters=[sigma_data_models.filter('account_name', kind='text-match', options={'mode': 'includes', 'value': 'Acme', 'case': false})],
)
```

---

### sigma_data_models.column
([source](macros/sigma/column.sql))

A column descriptor. Only needed when adding a calculated column or overriding a column's display name — bare strings are sufficient for passthrough columns.

Bare strings in `columns=[...]` produce a *passthrough* column: `{id, formula: '[stg_accounts/Account Guid]'}` with no `name` field, matching an unmodified source column in Sigma's own representation. Passing an explicit `formula` produces a *calculated* column: `{id, formula, name}`. Column names are always lowercased and must be unique within a table; a duplicate raises a compiler error.

**Args:**

- `name` (required): Column name (lowercased). Used as the display name and as the key for folder/filter references.
- `formula` (optional): Sigma formula string. Omit for a passthrough column; provide for a calculated column. Default is `none`.
- `display_name` (optional): Override the display name shown in Sigma. Default is `none` (derives from `name` via `titleize`).

**Usage:**

```sql
-- passthrough (bare string, preferred when no formula or display_name override needed)
columns=['account_guid', 'account_name']

-- calculated column
columns=[sigma_data_models.column('days_since_created', formula='DateDiff("day", [Created At], Now())')]

-- display name override only
columns=[sigma_data_models.column('account_guid', display_name='Account ID')]
```

---

### sigma_data_models.metric
([source](macros/sigma/metric.sql))

A metric descriptor. Only needed when overriding a metric's display name — plain `{name: formula}` dicts are sufficient otherwise.

Metric names must be unique within a table; a duplicate raises a compiler error.

**Args:**

- `name` (required): Metric name. Used as the key and default display name.
- `formula` (required): Sigma formula string for the metric.
- `display_name` (optional): Override the display name shown in Sigma. Default is `none` (derives from `name` via `titleize`).

**Usage:**

```sql
-- plain dict (preferred when no display_name override needed)
metrics={'count_accounts': 'CountDistinct([Account Guid])'}

-- display name override
metrics=[sigma_data_models.metric('count_accounts', formula='CountDistinct([Account Guid])', display_name='# Accounts')]
```

---

### sigma_data_models.relationship
([source](macros/sigma/relationship.sql))

A declared lineage link between two tables in the same model. Only needed when overriding the relationship's display name — bare tuples are sufficient otherwise.

A relationship in Sigma is a lineage link used for cross-table calculations, not a row-blending join (joins aren't modeled by this package — see [Coverage](#coverage)). `from`/`to` must reference a `key` present in the same `sigma_data_models.model()` call, and `from_column`/`to_column` must be actual columns on those tables — any mismatch raises a compiler error. The same `(from, from_column, to, to_column)` combination can't appear twice; a duplicate raises a compiler error.

**Args:**

- `from` (required): `key` of the source table.
- `from_column` (required): Column name on the source table.
- `to` (required): `key` of the target table.
- `to_column` (required): Column name on the target table.
- `name` (optional): Display name for the relationship. Default is `none`.

**Usage:**

```sql
-- bare tuple (preferred when no name override needed)
relationships=[
  ('accounts', 'account_owner_user_guid', 'employees', 'employee_guid'),
]

-- named relationship
relationships=[
  sigma_data_models.relationship('accounts', 'account_owner_user_guid', 'employees', 'employee_guid', name='Account Owner'),
]
```

---

### sigma_data_models.folder
([source](macros/sigma/folder.sql))

Groups a named subset of a table's columns and/or metrics for display in Sigma. Each entry in `columns` must be an actual column, and each entry in `metrics` an actual metric, on the table — either raises a compiler error otherwise. Folder names must be unique within a table; a duplicate raises a compiler error.

**Args:**

- `name` (required): Display name for the folder.
- `columns` (optional): List of column names (strings) to include in the folder — must all be actual columns on the table. Default is `[]`.
- `metrics` (optional): List of metric names (strings) to include in the folder — must all be actual metrics on the table. Default is `[]`.

**Usage:**

```sql
folders=[
  sigma_data_models.folder('Identifiers', columns=['account_guid']),
  sigma_data_models.folder('Attributes',  columns=['account_name', 'account_industry']),
  sigma_data_models.folder('Metrics',     metrics=['count_accounts', 'sum_arr_usd']),
]
```

---

### sigma_data_models.filter
([source](macros/sigma/filter.sql))

A filter on a table column. `kind`-specific fields are passed straight through in `options`, using Sigma's own field names directly — there's no per-`kind` macro surface to keep in sync with Sigma's filter types.

`column` must be an actual column on the table, or `sigma_data_models.table()` raises a compiler error. A table can only have one filter per `column`/`kind` pair; a duplicate raises a compiler error. `options` cannot set `id`, `columnId`, or `kind` — those are derived from `column`/`kind` and attempting to override them raises a compiler error.

**Args:**

- `column` (required): Name of the column to filter on — must be an actual column on the table.
- `kind` (required): Sigma filter type (e.g. `'list'`, `'text-match'`, `'number-range'`, `'date-range'`).
- `options` (optional): Dict of `kind`-specific fields using Sigma's own field names (e.g. `min`/`max` for `'number-range'`, `mode`/`value`/`case` for `'text-match'`, `mode`/`values` for `'list'`). Default is `{}`.

**Usage:**

```sql
filters=[
  sigma_data_models.filter('account_industry', kind='list',         options={'mode': 'include', 'values': ['Manufacturing', 'Retail']}),
  sigma_data_models.filter('employee_count',   kind='number-range', options={'min': 10, 'max': 500}),
]
```

---

### sigma_data_models.format
([source](macros/sigma/format.sql))

Constructs a Sigma format object controlling number or datetime display formatting on a column or metric. Pass the result as `format=` to `sigma_data_models.column()` or `sigma_data_models.metric()`. A raw dict is also accepted if you prefer to pass the Sigma format spec verbatim.

**Args:**

- `kind` (required): `'number'` or `'datetime'`. Any other value raises a compiler error.
- `options` (optional): Dict of format-specific fields using Sigma's own field names. Keys are validated at compile time — unsupported keys raise a compiler error. For `kind='number'`: `formatString`, `decimalSymbol`, `digitGroupingSymbol`, `digitGroupingSize`, `currencySymbol`. For `kind='datetime'`: `formatString` only. Default is `{}`.

**Usage:**

```sql
-- currency column
columns=[
  sigma_data_models.column('revenue', formula='[Revenue]',
    format=sigma_data_models.format('number', {'formatString': '$.2f', 'currencySymbol': '$'})),
]

-- date column
columns=[
  sigma_data_models.column('created_at', format=sigma_data_models.format('datetime', {'formatString': 'MM/DD/YYYY'})),
]

-- metric
metrics=[
  sigma_data_models.metric('count_accounts', 'CountDistinct([Account Guid])',
    format=sigma_data_models.format('number', {'formatString': 'd'})),
]
```

---

### sigma_data_models.materialize
([source](macros/sigma/materialize.sql))

Wires a composed spec into the dbt model's `config(meta=...)` so it lands in `manifest.json` on `dbt parse`/`dbt compile`.

Note that `config(meta=...)` replaces `meta` wholesale rather than merging — if the model or a `+meta:` block in `dbt_project.yml` sets other `meta` keys, calling `materialize()` will drop them. Keep these models single-purpose and set any other `meta` on a different model.

**Args:**

- `spec` (required): The composed spec returned by `sigma_data_models.model()`.
- `materialized` (optional): dbt materialization for the model. Default is `'view'`.

**Usage:**

```sql
{{ sigma_data_models.materialize(sigma_data_model) }}
```

## Connection tags

`connection_tags` on `model()` declares version tags that point the same data model at a different Sigma connection (one per region or environment). `materialize()` emits them as `meta.sigma_data_model_connection_tags`, next to `meta.sigma_data_model`; the spec itself doesn't change. A downstream sync tool uses them to call `POST /v2/dataModels/tag` with `sourceMappingConfig`. This package never calls the API.

```sql
connection_tags=[
  {'name': 'EU', 'connection_id': 'conn-eu', 'paths': [
    {'from_path': ['dbt_sigma', 'usage'], 'to_path': ['eu_dbt_sigma', 'usage']},
  ]},
]
```

- `name` (unique) and `connection_id` are required; `connectionId` is accepted as an alias.
- `paths` is optional. Each entry takes `from_path` and `to_path` (both required together) and optionally `from_connection_id` (must match a table's connection). camelCase spellings are accepted.
- A path is a list of 1 to 3 non-empty strings: `[database]`, `[database, schema]` or `[database, schema, table]`.
- A `from_path` may appear only once per tag.
- When entries overlap (say a schema-level path plus a table-level path for a table in that schema), resolution is up to Sigma's tag API; this package doesn't resolve or check it.
- Validation runs in `model()`. A model that sets `meta.sigma_data_model_connection_tags` by hand skips it.

### sigma_data_models.connection_tag_paths
([source](macros/sigma/connection_tags.sql))

Builds table-level `paths` from a list of tables, so a tag doesn't need one hand-written entry per table. `to_database` / `to_schema` override that part of each table's own path; the table name is kept. Concatenate calls to map table groups to different databases, e.g. regionally built tables next to tables replicated from a primary region:

```sql
{% set local = [sigma_data_models.table('usage', 'usage_events', columns=['event_id'])] %}
{% set replicated = [sigma_data_models.table('accounts', 'accounts', columns=['account_guid'])] %}
{% set spec = sigma_data_models.model(
    name='Usage',
    tables=local + replicated,
    connection_tags=[{
      'name': 'EU',
      'connection_id': 'conn-eu',
      'paths': sigma_data_models.connection_tag_paths(local, to_database='dbt_sigma')
             + sigma_data_models.connection_tag_paths(replicated, to_database='dbt_sigma_replication'),
    }],
) %}
```

## Frozen element ids

`id` is never supplied by hand. Every table/column/metric/folder/filter's id comes from `sigma_data_models.freeze_id(path)`, which is `local_md5(path)` over a path built from `key` plus the table's physical `database.schema.identifier` (together, `freeze_scope`) — `'table:' ~ freeze_scope`, `'column:' ~ freeze_scope ~ '.' ~ column.name`, `'metric:' ~ freeze_scope ~ '.' ~ metric.name`, `'folder:' ~ freeze_scope ~ '.' ~ folder.name`, `'filter:' ~ freeze_scope ~ '.' ~ column.name ~ '.' ~ kind`. Relationship ids use `'relationship:' ~ from ~ '_to_' ~ to ~ '_' ~ from_column ~ '_' ~ to_column` instead (table keys, not `freeze_scope`) — `to_column` is included so two relationships between the same table pair on the same `from_column` (e.g. a polymorphic join) don't collide.

Both `key` and the identifier matter here, for different reasons: the identifier ties the id to a real, physical binding (renaming a `display_name`, `description`, or reordering columns never reshuffles ids, so recompiling the same model doesn't produce a spurious diff); `key` is what keeps two occurrences of the *same* physical table within one model distinct — e.g. a self-join binding `employees` twice, once as `'employees'` and once as `'managers'`, needs each occurrence (and its columns) to get its own id, not collide. Since `key` is already required to be unique within a single `sigma_data_models.model()` call (see above), combining it with the identifier is enough to guarantee uniqueness there without needing ids to be globally unique across separate models — the same `key` (e.g. `'accounts'`) can still be reused across *unrelated* data models freely, since there's no requirement that ids be unique beyond a single model's own `pages[0].elements`.

The identifier portion is lowercased before hashing, so the same physical table freezes to the same id regardless of the casing it's bound with (holding `key` constant) — e.g. Snowflake uppercases unquoted identifiers, so a `database`/`schema` typed differently across two callers (or two environments) would otherwise silently produce two different ids for what's really one table.

`dataModelId` is the one exception — it's `none` unless explicitly passed via `sigma_data_models.model(data_model_id=...)`, since it's assigned by Sigma the first time a data model is created (there's nothing to freeze before that). Pass it back in once known to target an update instead of a create. `pages[0].id` also has no frozen value — it's always left `''`, since [creating a data model from a code representation](https://help.sigmacomputing.com/docs/create-a-data-model-from-a-code-representation) documents that Sigma assigns it and expects it blank.

What this does **not** guarantee for the ids this package *does* freeze (table/column/metric/folder/filter/relationship): Sigma-side permanence. Per Sigma's own docs, on the first live sync Sigma may assign its own internal id to an element, independent of what's frozen here — the only way to learn the real id is a round trip against the live API, which is outside what a dbt macro can do at compile time. So treat `freeze_id` as a guarantee of *compile-time* determinism (no diff noise across recompiles), not a promise that the id you see in `manifest.json` is the one Sigma ends up using.

`connection_id`/`folder_id` default to the `sigma_connection_id`/`sigma_folder_id` project vars (set once for the org/workspace), and can be overridden per table (`connection_id`) or per model (`folder_id`):

```yaml
# dbt_project.yml
vars:
  sigma_connection_id: 17edf046-9636-4d9b-a13f-d034bec2d600
  sigma_folder_id: e7c79c61-94d4-458e-ab4c-f581a4c04a4c
```

## Coverage

Modeled, matching Sigma's own [example representations](https://help.sigmacomputing.com/docs/data-model-representation-example-library):

- Warehouse-bound tables (`source.kind: "warehouse-table"`)
- Passthrough and calculated columns
- Metrics
- Relationships (declared lineage links, nested under their source table)
- Folders (named column groupings)
- Filters (`kind`-specific fields passed through verbatim)
- Column/metric `format` (number/datetime display formatting via `sigma_data_models.format()`)
- Multi-page data models (assign tables to named pages via `page=` on `sigma_data_models.table()`; tables without `page=` land on the default page)
- Controls (page-level interactive filter elements via `sigma_data_models.control()`, targeting one or more table columns; placed alongside table elements on their page)

Not modeled - unsupported inputs are simply not exposed by these macros, so there's nothing to accidentally get wrong:

- **Joins** (`source.kind: "join"`) - a distinct element that blends two tables' rows, different from a relationship (see above)
- **Unions** (`source.kind: "union"`) - a distinct element combining multiple sources by matched columns
- **Transposed tables** (`source.kind: "transpose"`) - a distinct element pivoting a source table's columns to rows
- Custom SQL sources (`source.kind: "sql"`)
- Groupings (statistical `groupBy`, distinct from folders)
- Column-level security (`columnSecurities`)

## Why a model instead of a plain YAML block

dbt only exposes `var()`/`env_var()` (not `ref()` or custom macros) to the Jinja context used to render `exposures:`/`models:` YAML properties, so the spec can't be composed there. A `.sql` model file gets the full macro/`ref()` context, so that's where composition happens; the model's `select` body is intentionally inert.

## Integration tests

See `integration_tests/` for a runnable example (seeds + staging models + a `sigma_*` model exercising every supported shape + a companion exposure), and `integration_tests/README.md` for which Sigma example each shape is checked against. From `integration_tests/`:

```bash
dbt deps
DBT_PROFILES_DIR=. dbt parse --no-partial-parse
```
