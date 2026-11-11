{% macro table(key, identifier=none, database=none, schema=none, connection_id=none, columns=[], metrics=[], folders=[], filters=[], display_name=none, page=none, freeze_name=none, freeze_schema=none) %}
{% set database = database or target.database %}
{% set schema = schema or target.schema %}
{% set identifier = identifier or key %}
{% set connection_id = connection_id or var('sigma_connection_id', none) %}
{% if not connection_id and execute %}
  {% do exceptions.raise_compiler_error(
    "sigma_data_models.table('" ~ key ~ "'): connection_id is required but was not set. " ~
    "Pass connection_id= to sigma_data_models.table(), or set the `sigma_connection_id` project variable in dbt_project.yml."
  ) %}
{% endif %}
{# Element ids are frozen off `key` plus the physical db.schema.identifier a table is bound
   to - both, not just one. `key` alone would let two different physical tables collide if two
   models happened to reuse the same key; the identifier alone would let the same physical
   table collide with itself when referenced twice in one model under different keys (a
   self-join, e.g. 'employees' bound twice as 'employees' and 'managers') - ids only need to be
   unique within a single sigma_data_models.model() call, and `key` is already enforced unique
   there, so combining both is sufficient and self-joins get distinct ids for free. The
   identifier portion is lowercased because unquoted identifiers get uppercased by some
   adapters (e.g. Snowflake) - without this, the same physical table could freeze to different
   ids depending on which casing a caller (or environment) happens to pass in. #}
{# `freeze_name` / `freeze_schema`, when set, stand in for `identifier` / `schema` in the hashed
   path only, so a warehouse rename or schema move (or dev vs prod `target.schema`) doesn't re-id
   the table. `source.path` and default formulas still use the real values, since those must
   match the live catalog. Unset/empty falls back to the real value. They are independent. #}
{% set freeze_identifier = freeze_name or identifier %}
{% set hash_schema = freeze_schema or schema %}
{% set identifier_path = (database ~ '.' ~ hash_schema ~ '.' ~ freeze_identifier) | lower %}
{% set freeze_scope = key ~ '@' ~ identifier_path %}

{% if not columns %}
  {% if not execute %}
    {% do exceptions.raise_compiler_error(
      "sigma_data_models.table('" ~ key ~ "'): columns were left empty, which auto-populates them from " ~
      database ~ "." ~ schema ~ "." ~ identifier ~ " - that requires a live connection, so it " ~
      "only works under `dbt run`/`dbt compile`, not `dbt parse`. Pass `columns` explicitly to " ~
      "compile without a connection."
    ) %}
  {% endif %}
  {% set relation = api.Relation.create(database=database, schema=schema, identifier=identifier) %}
  {% set columns = [] %}
  {% for relation_column in adapter.get_columns_in_relation(relation) %}
    {% do columns.append(relation_column.name) %}
  {% endfor %}
  {% if not columns %}
    {% do exceptions.raise_compiler_error(
      "sigma_data_models.table('" ~ key ~ "'): auto-populating columns from " ~
      database ~ "." ~ schema ~ "." ~ identifier ~ " found none - the relation likely doesn't " ~
      "exist yet (check `identifier`/`database`/`schema`, and that it's been built) or has no " ~
      "columns."
    ) %}
  {% endif %}
{% endif %}

{% set frozen_columns = [] %}
{% set column_ids = {} %}
{% for column in columns %}
  {% set column = sigma_data_models.column(column) if column is string else column %}
  {% if column.name in column_ids %}
    {% do exceptions.raise_compiler_error("sigma_data_models.table('" ~ key ~ "'): duplicate column name '" ~ column.name ~ "' - column names must be unique within a table.") %}
  {% endif %}
  {# Passthrough columns auto-generate a [identifier/Titleized Name] formula reference. Sigma's
     formula parser title-cases column names differently than Python's str.title() at
     letter/digit boundaries (e.g. L30 -> "L 30"), so any digit in the name risks producing a
     formula that doesn't match the live catalog title — guard here so the failure surfaces at
     compile time rather than as an opaque API rejection. #}
  {% if not column.formula %}
    {% set ns = namespace(has_digit=false) %}
    {% for char in column.name %}
      {% if char.isdigit() %}{% set ns.has_digit = true %}{% endif %}
    {% endfor %}
    {% if ns.has_digit %}
      {% do exceptions.raise_compiler_error(
        "sigma_data_models.table('" ~ key ~ "'): passthrough column '" ~ column.name ~
        "' contains a digit — Sigma's formula parser title-cases column names differently " ~
        "than Python's str.title() at letter/digit boundaries, so the auto-derived formula " ~
        "may not resolve. Supply an explicit formula= to sigma_data_models.column() to " ~
        "override, or omit this column."
      ) %}
    {% endif %}
  {% endif %}
  {% set column_id = sigma_data_models.freeze_id('column:' ~ freeze_scope ~ '.' ~ column.name) %}
  {% do column_ids.update({column.name: column_id}) %}
  {# A pure passthrough column (no `formula`, no `display_name`) carries only {id, formula},
     matching Sigma's representation of an unmodified source column. Supplying `formula` OR
     `display_name` (or both) promotes it to a calculated column shape {id, formula, name} -
     a display_name-only column is effectively an identity calculated column (same formula,
     just with a non-default label). #}
  {% set entry = {
    "id": column_id,
    "formula": column.formula or ('[' ~ identifier ~ '/' ~ sigma_data_models.titleize(column.name) ~ ']'),
  } %}
  {% if column.formula or column.display_name %}
    {% do entry.update({"name": column.display_name or sigma_data_models.titleize(column.name)}) %}
  {% endif %}
  {% if column.format %}
    {% if column.format.get('kind') not in ['number', 'datetime'] %}
      {% do exceptions.raise_compiler_error(
        "sigma_data_models.table('" ~ key ~ "'): column '" ~ column.name ~ "' has format.kind '" ~ column.format.get('kind') ~ "' - must be 'number' or 'datetime'. Use sigma_data_models.format() to construct a valid format dict."
      ) %}
    {% endif %}
    {% do entry.update({"format": column.format}) %}
  {% endif %}
  {% do frozen_columns.append(entry) %}
{% endfor %}

{% set frozen_metrics = [] %}
{% set metric_ids = {} %}
{% set metrics_is_mapping = metrics is mapping %}
{% set metric_names = [] %}
{% for metric in (metrics.items() if metrics_is_mapping else metrics) %}
  {% set metric = sigma_data_models.metric(metric[0], metric[1]) if metrics_is_mapping else metric %}
  {% if metric.name in metric_names %}
    {% do exceptions.raise_compiler_error("sigma_data_models.table('" ~ key ~ "'): duplicate metric name '" ~ metric.name ~ "' - metric names must be unique within a table.") %}
  {% endif %}
  {% do metric_names.append(metric.name) %}
  {% set metric_id = sigma_data_models.freeze_id('metric:' ~ freeze_scope ~ '.' ~ metric.name) %}
  {% do metric_ids.update({metric.name: metric_id}) %}
  {% set metric_entry = {
    "id": metric_id,
    "formula": metric.formula,
    "name": metric.display_name or sigma_data_models.titleize(metric.name),
  } %}
  {% if metric.format %}
    {% if metric.format.get('kind') not in ['number', 'datetime'] %}
      {% do exceptions.raise_compiler_error(
        "sigma_data_models.table('" ~ key ~ "'): metric '" ~ metric.name ~ "' has format.kind '" ~ metric.format.get('kind') ~ "' - must be 'number' or 'datetime'. Use sigma_data_models.format() to construct a valid format dict."
      ) %}
    {% endif %}
    {% do metric_entry.update({"format": metric.format}) %}
  {% endif %}
  {% do frozen_metrics.append(metric_entry) %}
{% endfor %}

{% set frozen_folders = [] %}
{% set folder_names = [] %}
{% for folder in folders %}
  {% if folder.name in folder_names %}
    {% do exceptions.raise_compiler_error("sigma_data_models.table('" ~ key ~ "'): duplicate folder name '" ~ folder.name ~ "' - folder names must be unique within a table.") %}
  {% endif %}
  {% do folder_names.append(folder.name) %}
  {% set items = [] %}
  {% for column_name in folder.columns %}
    {% set column_name = column_name | lower %}
    {% if column_name not in column_ids %}
      {% do exceptions.raise_compiler_error("sigma_data_models.table('" ~ key ~ "'): folder '" ~ folder.name ~ "' references unknown column '" ~ column_name ~ "' - must be one of " ~ (column_ids.keys() | list)) %}
    {% endif %}
    {% do items.append(column_ids[column_name]) %}
  {% endfor %}
  {% for metric_name in folder.get('metrics', []) %}
    {% set metric_name = metric_name | lower %}
    {% if metric_name not in metric_ids %}
      {% do exceptions.raise_compiler_error("sigma_data_models.table('" ~ key ~ "'): folder '" ~ folder.name ~ "' references unknown metric '" ~ metric_name ~ "' - must be one of " ~ (metric_ids.keys() | list)) %}
    {% endif %}
    {% do items.append(metric_ids[metric_name]) %}
  {% endfor %}
  {% do frozen_folders.append({
    "id": sigma_data_models.freeze_id('folder:' ~ freeze_scope ~ '.' ~ folder.name),
    "name": folder.name,
    "items": items,
  }) %}
{% endfor %}

{% set frozen_filters = [] %}
{% set filter_keys = [] %}
{% for filter in filters %}
  {% if filter.column not in column_ids %}
    {% do exceptions.raise_compiler_error("sigma_data_models.table('" ~ key ~ "'): filter references unknown column '" ~ filter.column ~ "' - must be one of " ~ (column_ids.keys() | list)) %}
  {% endif %}
  {% set filter_key = filter.column ~ '.' ~ filter.kind %}
  {% if filter_key in filter_keys %}
    {% do exceptions.raise_compiler_error("sigma_data_models.table('" ~ key ~ "'): duplicate filter '" ~ filter_key ~ "' - a table can only have one filter per column/kind pair.") %}
  {% endif %}
  {% do filter_keys.append(filter_key) %}
  {% for reserved_key in ['id', 'columnId', 'kind'] %}
    {% if reserved_key in filter.options %}
      {% do exceptions.raise_compiler_error("sigma_data_models.table('" ~ key ~ "'): filter options can't set '" ~ reserved_key ~ "' - it's already set from `column`/`kind` and would silently overwrite the frozen value.") %}
    {% endif %}
  {% endfor %}
  {% set frozen_filter = {
    "id": sigma_data_models.freeze_id('filter:' ~ freeze_scope ~ '.' ~ filter_key),
    "columnId": column_ids[filter.column],
    "kind": filter.kind,
  } %}
  {% do frozen_filter.update(filter.options) %}
  {% do frozen_filters.append(frozen_filter) %}
{% endfor %}

{% set order = [] %}
{% for column in frozen_columns %}
  {% do order.append(column.id) %}
{% endfor %}

{# `key`, `_column_ids`, and `_page` are internal-only - sigma_data_models.model() reads them to
   resolve relationships/folders and group tables into pages, then strips all three before
   emitting the final Sigma element, since none are real fields in Sigma's schema. #}
{% set element = {
  "key": key,
  "_column_ids": column_ids,
  "id": sigma_data_models.freeze_id('table:' ~ freeze_scope),
  "kind": "table",
  "name": display_name or sigma_data_models.titleize(key),
  "source": {
    "connectionId": connection_id,
    "kind": "warehouse-table",
    "path": [database, schema, identifier],
  },
  "columns": frozen_columns,
  "order": order,
} %}
{% if frozen_metrics %}
  {% do element.update({"metrics": frozen_metrics}) %}
{% endif %}
{% if frozen_folders %}
  {% do element.update({"folders": frozen_folders}) %}
{% endif %}
{% if frozen_filters %}
  {% do element.update({"filters": frozen_filters}) %}
{% endif %}
{% do element.update({"_page": page}) %}
{% do return(element) %}
{% endmacro %}
