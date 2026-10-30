{# Asserts the composed spec's *shape* matches Sigma's real data-model-as-code schema, as
   documented at https://help.sigmacomputing.com/docs/data-model-representation-example-library
   - not just that compilation doesn't error. See integration_tests/README.md for which
   specific Sigma examples each assertion corresponds to. #}
{% macro assert_sigma_spec() %}

{% set model_spec = sigma_data_models.model(
  name='Shape Check',
  tables=[
    sigma_data_models.table('accounts_shape_check', identifier='accounts',
      columns=[
        'account_guid',
        'account_owner_user_guid',
        sigma_data_models.column('is_named_acme', formula="[Account Name] = 'Acme Corp'"),
        sigma_data_models.column('account_guid_formatted', display_name='Account GUID',
          format=sigma_data_models.format('number', {'formatString': '$.2f', 'currencySymbol': '$'})),
      ],
      metrics=[
        sigma_data_models.metric('count_accounts', 'CountDistinct([Account Guid])',
          format=sigma_data_models.format('number', {'formatString': 'd'})),
      ],
      folders=[sigma_data_models.folder('Identifiers', columns=['account_guid'])],
      filters=[sigma_data_models.filter('account_owner_user_guid', kind='list', options={'mode': 'include', 'values': ['e1']})]),
    sigma_data_models.table('employees_shape_check', identifier='employees',
      columns=['employee_guid']),
  ],
  relationships=[('accounts_shape_check', 'account_owner_user_guid', 'employees_shape_check', 'employee_guid')],
  controls=[
    sigma_data_models.control('owner_filter', type='list',
      targets=[('accounts_shape_check', 'account_owner_user_guid')],
      display_name='Account Owner'),
  ],
  folder_id='test-folder-id',
) %}

{# Top-level shape: dataModelId/name/folderId/schemaVersion/pages, matching the "create a data
   model from a code representation" request schema - see
   example-representation-data-model-with-a-single-table.md and
   create-a-data-model-from-a-code-representation.md. #}
{% if model_spec.schemaVersion != 1 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: schemaVersion must be 1') %}
{% endif %}
{% if model_spec.folderId != 'test-folder-id' %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: folderId must pass through from the folder_id arg') %}
{% endif %}
{% if model_spec.pages | length != 1 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: model() must produce exactly one page') %}
{% endif %}
{% set page = model_spec.pages[0] %}
{% if page.id != sigma_data_models.freeze_id('page:' ~ page.name) %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: page.id must be frozen from the page name (an empty id is rejected by Sigma when a page is added to an existing model), got '" ~ page.id ~ "'") %}
{% endif %}
{% if page.elements | length != 3 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: page must contain one element per table plus one per control, got ' ~ (page.elements | length)) %}
{% endif %}

{% set accounts_element = page.elements[0] %}
{% set employees_element = page.elements[1] %}
{% set control_element = page.elements[2] %}

{# Table element shape: id/kind/source/columns/order, matching
   example-representation-data-model-with-a-single-table.md. Internal-only fields (`key`,
   `_column_ids`) must not leak into the emitted element. #}
{% if accounts_element.kind != 'table' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: table element kind must be 'table'") %}
{% endif %}
{% if 'key' in accounts_element or '_column_ids' in accounts_element or '_page' in accounts_element %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: internal-only fields (key, _column_ids, _page) must not appear in the emitted element') %}
{% endif %}
{% if accounts_element.source.kind != 'warehouse-table' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: source.kind must be 'warehouse-table'") %}
{% endif %}
{% if accounts_element.source.path | length != 3 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: source.path must be a 3-element [database, schema, identifier] list') %}
{% endif %}
{% if accounts_element.source.path[2] != 'accounts' %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: source.path[2] must be the bound identifier') %}
{% endif %}

{# Table element name: defaults to titleize(key), or explicit display_name when supplied. #}
{% if accounts_element.name != 'Accounts Shape Check' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: table name must default to titleize(key), got '" ~ accounts_element.name ~ "'") %}
{% endif %}
{% set named_table = sigma_data_models.table('named_check', identifier='accounts', columns=['account_guid'], display_name='Custom Label') %}
{% if named_table.name != 'Custom Label' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: table display_name must pass through as name, got '" ~ named_table.name ~ "'") %}
{% endif %}

{# Passthrough column shape: {id, formula} only - no `name` key, matching
   example-representation-data-model-with-a-single-table.md. #}
{% set passthrough_column = accounts_element.columns[0] %}
{% if passthrough_column.keys() | list | sort != ['formula', 'id'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a passthrough column must have exactly {id, formula}, got ' ~ (passthrough_column.keys() | list)) %}
{% endif %}
{% if passthrough_column.formula != '[accounts/Account Guid]' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: a passthrough column's formula must default to '[identifier/Titleized Name]', got " ~ passthrough_column.formula) %}
{% endif %}

{# Calculated column shape: {id, formula, name}, matching
   example-representation-data-model-with-a-table-and-a-calculated-column.md. #}
{% set calculated_column = accounts_element.columns[2] %}
{% if calculated_column.keys() | list | sort != ['formula', 'id', 'name'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a calculated column must have exactly {id, formula, name}, got ' ~ (calculated_column.keys() | list)) %}
{% endif %}
{% if calculated_column.name != 'Is Named Acme' %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a calculated column name must default to a title-cased version of its key') %}
{% endif %}

{# Column with format: {id, formula, name, format} - display_name + format on a passthrough column. #}
{% set formatted_column = accounts_element.columns[3] %}
{% if formatted_column.keys() | list | sort != ['format', 'formula', 'id', 'name'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a column with display_name and format must have exactly {format, formula, id, name}, got ' ~ (formatted_column.keys() | list)) %}
{% endif %}
{% if formatted_column.name != 'Account GUID' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: formatted column name must use display_name, got '" ~ formatted_column.name ~ "'") %}
{% endif %}
{% if formatted_column.format.kind != 'number' or formatted_column.format.formatString != '$.2f' or formatted_column.format.currencySymbol != '$' %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: format fields did not pass through correctly, got ' ~ formatted_column.format) %}
{% endif %}

{# Passthrough column with format only (no display_name): must emit {id, formula, format} - no `name`. #}
{% set fmt_passthrough_table = sigma_data_models.table('fmt_passthrough_check', identifier='accounts', columns=[
  sigma_data_models.column('account_guid', format=sigma_data_models.format('number', {'formatString': 'd'}))
]) %}
{% set fmt_passthrough_col = fmt_passthrough_table.columns[0] %}
{% if fmt_passthrough_col.keys() | list | sort != ['format', 'formula', 'id'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a passthrough column with format (no display_name) must have exactly {format, formula, id}, got ' ~ (fmt_passthrough_col.keys() | list)) %}
{% endif %}
{% if fmt_passthrough_col.format.kind != 'number' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: passthrough format.kind must pass through, got '" ~ fmt_passthrough_col.format.kind ~ "'") %}
{% endif %}

{# display_name-only passthrough: must emit {id, formula, name} with the given display_name,
   not silently fall back to titleize(column.name). #}
{% set dn_table = sigma_data_models.table('display_name_col_check', identifier='accounts', columns=[
  sigma_data_models.column('account_owner_user_guid', display_name='Account Owner ID')
]) %}
{% set dn_col = dn_table.columns[0] %}
{% if dn_col.keys() | list | sort != ['formula', 'id', 'name'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a display_name-only column must have exactly {id, formula, name}, got ' ~ (dn_col.keys() | list)) %}
{% endif %}
{% if dn_col.name != 'Account Owner ID' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: a display_name-only column must use the display_name as its name, got '" ~ dn_col.name ~ "'") %}
{% endif %}
{% set expected_dn_formula = '[' ~ dn_table.source.path[2] ~ '/' ~ sigma_data_models.titleize('account_owner_user_guid') ~ ']' %}
{% if dn_col.formula != expected_dn_formula %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: a display_name-only column's formula must still auto-generate to '[identifier/Titleized Name]', got " ~ dn_col.formula) %}
{% endif %}

{# order must be exactly the column ids, in declaration order. #}
{% set expected_order = [] %}
{% for c in accounts_element.columns %}
  {% do expected_order.append(c.id) %}
{% endfor %}
{% if accounts_element.order != expected_order %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: order must be exactly the column ids in declaration order') %}
{% endif %}

{# Metric shape: {id, formula, name}, matching
   example-representation-data-model-with-a-table-and-a-metric.md. Metrics only appear on a
   table when at least one was supplied. #}
{% if 'metrics' not in employees_element %}
  {# employees_shape_check has no metrics - correctly omitted, not an empty list. #}
{% else %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a table with no metrics must omit the `metrics` key entirely') %}
{% endif %}
{% set metric = accounts_element.metrics[0] %}
{% if metric.keys() | list | sort != ['format', 'formula', 'id', 'name'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a metric with format must have exactly {id, formula, name, format}, got ' ~ (metric.keys() | list)) %}
{% endif %}
{% if metric.formula != 'CountDistinct([Account Guid])' or metric.name != 'Count Accounts' %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: metric formula/name did not pass through correctly') %}
{% endif %}
{% if metric.format.kind != 'number' or metric.format.formatString != 'd' %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: metric format fields did not pass through correctly, got ' ~ metric.format) %}
{% endif %}

{# Metric shape without format: {id, formula, name} only - no `format` key. #}
{% set no_format_table = sigma_data_models.table('no_format_metric_check', identifier='accounts', columns=['account_guid'],
  metrics=[sigma_data_models.metric('count_nofmt', 'Count([Account Guid])')]) %}
{% set no_format_metric = no_format_table.metrics[0] %}
{% if no_format_metric.keys() | list | sort != ['formula', 'id', 'name'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a metric without format must have exactly {id, formula, name}, got ' ~ (no_format_metric.keys() | list)) %}
{% endif %}

{# Folder shape: {id, name, items}, matching example-representation-data-model-with-a-folder.md. #}
{% set folder = accounts_element.folders[0] %}
{% if folder.keys() | list | sort != ['id', 'items', 'name'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a folder must have exactly {id, name, items}, got ' ~ (folder.keys() | list)) %}
{% endif %}
{% if folder['items'] != [passthrough_column.id] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: folder.items must be the ids of its member columns') %}
{% endif %}

{# Folder with metrics: items must include both column and metric ids, columns first then
   metrics, each in declared order (AE-20 / issue #20 - metric folders). #}
{% set folder_with_metrics_table = sigma_data_models.table('folder_metrics_check', identifier='accounts',
  columns=['account_guid', 'account_owner_user_guid'],
  metrics=[
    sigma_data_models.metric('count_accounts', 'CountDistinct([Account Guid])'),
    sigma_data_models.metric('count_owners', 'CountDistinct([Account Owner User Guid])'),
  ],
  folders=[sigma_data_models.folder('Mixed', columns=['account_guid'], metrics=['count_accounts', 'count_owners'])]) %}
{% set mixed_folder = folder_with_metrics_table.folders[0] %}
{% set expected_mixed_items = [
  folder_with_metrics_table.columns[0].id,
  folder_with_metrics_table.metrics[0].id,
  folder_with_metrics_table.metrics[1].id,
] %}
{% if mixed_folder['items'] != expected_mixed_items %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a folder with both columns and metrics must order items as columns first, then metrics, each in declared order, got ' ~ mixed_folder['items']) %}
{% endif %}

{# A metrics-only folder (no columns) must still resolve correctly. #}
{% set metrics_only_folder_table = sigma_data_models.table('metrics_only_folder_check', identifier='accounts', columns=['account_guid'],
  metrics=[sigma_data_models.metric('count_accounts', 'CountDistinct([Account Guid])')],
  folders=[sigma_data_models.folder('Metrics', metrics=['count_accounts'])]) %}
{% set metrics_only_folder = metrics_only_folder_table.folders[0] %}
{% if metrics_only_folder['items'] != [metrics_only_folder_table.metrics[0].id] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a metrics-only folder must resolve items to the metric ids, got ' ~ metrics_only_folder['items']) %}
{% endif %}

{# Filter shape: {id, columnId, kind, ...kind-specific fields verbatim}, matching
   example-representation-data-model-with-filters.md. #}
{% set filter = accounts_element.filters[0] %}
{% if filter.keys() | list | sort != ['columnId', 'id', 'kind', 'mode', 'values'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a list filter must have exactly {id, columnId, kind, mode, values}, got ' ~ (filter.keys() | list)) %}
{% endif %}
{% if filter.columnId != accounts_element.columns[1].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: filter.columnId must be the resolved column id') %}
{% endif %}
{% if filter.kind != 'list' or filter.mode != 'include' or filter['values'] != ['e1'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: filter kind-specific fields did not pass through verbatim') %}
{% endif %}

{# Relationship shape: nests inside the *source* table's element (not at the model level), as
   {id, targetElementId, keys: [{sourceColumnId, targetColumnId}], name}, matching
   example-representation-data-model-with-a-table-and-a-relationship.md. #}
{% if 'relationships' in employees_element %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: relationships must nest under the source (from) table, not the target (to) table') %}
{% endif %}
{% set relationship = accounts_element.relationships[0] %}
{% if relationship.keys() | list | sort != ['id', 'keys', 'name', 'targetElementId'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a relationship must have exactly {id, targetElementId, keys, name}, got ' ~ (relationship.keys() | list)) %}
{% endif %}
{% if relationship.targetElementId != employees_element.id %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: relationship.targetElementId must be the target table's real element id") %}
{% endif %}
{% if relationship['keys'] | length != 1 or relationship['keys'][0].keys() | list | sort != ['sourceColumnId', 'targetColumnId'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: relationship.keys must be a list of {sourceColumnId, targetColumnId}') %}
{% endif %}
{% if relationship['keys'][0].sourceColumnId != accounts_element.columns[1].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: relationship sourceColumnId must be the resolved from_column id') %}
{% endif %}
{% if relationship['keys'][0].targetColumnId != employees_element.columns[0].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: relationship targetColumnId must be the resolved to_column id') %}
{% endif %}
{% set expected_rel_name = sigma_data_models.titleize('accounts_shape_check') ~ ' → ' ~ sigma_data_models.titleize('employees_shape_check') %}
{% if relationship.name != expected_rel_name %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: relationship.name must default to titleize(from) ~ ' → ' ~ titleize(to) when no name is supplied, got '" ~ relationship.name ~ "'") %}
{% endif %}

{# Control shape: page-level element with {kind, id, controlId, controlType, name, filters},
   where filters resolves each target to {source: {kind: 'table', elementId}, columnId}. #}
{% if control_element.kind != 'control' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: control element kind must be 'control', got '" ~ control_element.kind ~ "'") %}
{% endif %}
{% if '_page' in control_element %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: internal-only field _page must not appear in the emitted control element') %}
{% endif %}
{% if control_element.controlId != 'owner_filter' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: control.controlId must be the name arg, got '" ~ control_element.controlId ~ "'") %}
{% endif %}
{% if control_element.controlType != 'list' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: control.controlType must be the type arg, got '" ~ control_element.controlType ~ "'") %}
{% endif %}
{% if control_element.name != 'Account Owner' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: control.name must use display_name when supplied, got '" ~ control_element.name ~ "'") %}
{% endif %}
{% if control_element.filters | length != 1 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a single-target control must produce exactly one filter entry') %}
{% endif %}
{% if control_element.filters[0].source.kind != 'table' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: control filter source.kind must be 'table'") %}
{% endif %}
{% if control_element.filters[0].source.elementId != accounts_element.id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: control filter source.elementId must resolve to the target table element id') %}
{% endif %}
{% if control_element.filters[0].columnId != accounts_element.columns[1].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: control filter columnId must resolve to the target column id') %}
{% endif %}

{# Control display_name defaults to titleize(name) when not supplied. #}
{% set default_name_control = sigma_data_models.model(
  name='Control Default Name Check',
  tables=[sigma_data_models.table('accounts_dn_check', identifier='accounts', columns=['account_guid'])],
  controls=[sigma_data_models.control('account_segment_filter', type='list',
    targets=[('accounts_dn_check', 'account_guid')])],
) %}
{% set dn_control = default_name_control.pages[0].elements[1] %}
{% if dn_control.name != 'Account Segment Filter' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: control.name must default to titleize(name) when display_name is not supplied, got '" ~ dn_control.name ~ "'") %}
{% endif %}

{# Multi-target control: targets=[] with two pairs must produce filters of length 2, each
   resolving to the correct table element and column. #}
{% set multi_target_spec = sigma_data_models.model(
  name='Multi Target Control Check',
  tables=[
    sigma_data_models.table('mt_accounts', identifier='accounts', columns=['account_guid', 'account_industry']),
    sigma_data_models.table('mt_employees', identifier='employees', columns=['employee_guid']),
  ],
  controls=[
    sigma_data_models.control('multi_filter', type='list',
      targets=[('mt_accounts', 'account_industry'), ('mt_employees', 'employee_guid')]),
  ],
) %}
{% set mt_control = multi_target_spec.pages[0].elements[2] %}
{% if mt_control.filters | length != 2 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a multi-target control must produce one filter entry per target, got ' ~ (mt_control.filters | length)) %}
{% endif %}
{% if mt_control.filters[0].source.elementId != multi_target_spec.pages[0].elements[0].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: multi-target control filter[0].source.elementId must resolve to the first target table') %}
{% endif %}
{% if mt_control.filters[1].source.elementId != multi_target_spec.pages[0].elements[1].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: multi-target control filter[1].source.elementId must resolve to the second target table') %}
{% endif %}

{# _resolve_table/_resolve_column_id helpers: verify they return the exact same ids that
   table() froze, confirming the model() refactor didn't silently change any frozen values.
   This matters because _resolve_column_id applies `| lower` to the column name before
   lookup - the assertion guards against that (or any future change) accidentally producing
   a different id than the one table() stored in _column_ids. #}
{% set resolve_check_table = sigma_data_models.table('resolve_check', identifier='accounts',
  columns=['account_guid', 'account_owner_user_guid']) %}
{% set resolve_check_tby_key = {'resolve_check': resolve_check_table} %}
{% set resolved_table = sigma_data_models._resolve_table('test', 'resolve_check', resolve_check_tby_key) %}
{% if resolved_table.id != resolve_check_table.id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: _resolve_table must return the same table dict (same id) as direct lookup') %}
{% endif %}
{% set resolved_col_id = sigma_data_models._resolve_column_id('test', 'resolve_check', resolve_check_table, 'account_guid') %}
{% if resolved_col_id != resolve_check_table._column_ids['account_guid'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: _resolve_column_id must return the same frozen id as direct _column_ids lookup') %}
{% endif %}

{# Pinned id regression guard: every frozen id below was captured from origin/main before
   the add-controls-as-first-class-elements branch was introduced and verified identical via
   a two-branch dbt run-operation diff. Any change to freeze_id(), the freeze_scope formula,
   column name handling, or the _resolve_* helpers that shifts a frozen id will fail here
   immediately, without needing a manual branch comparison.
   Key: sigma_data_models.table('accounts_cmp', identifier='accounts', ...)
        sigma_data_models.table('employees_cmp', identifier='employees', ...)
   connected via relationship accounts_cmp.account_owner_user_guid -> employees_cmp.employee_guid #}
{% set pin_t_accounts = sigma_data_models.table('accounts_cmp', identifier='accounts',
  columns=[
    'account_guid',
    'account_owner_user_guid',
    sigma_data_models.column('is_named_acme', formula="[Account Name] = 'Acme Corp'"),
  ],
  metrics=[sigma_data_models.metric('count_accounts', 'CountDistinct([Account Guid])')],
  folders=[sigma_data_models.folder('Identifiers', columns=['account_guid'])],
  filters=[sigma_data_models.filter('account_owner_user_guid', kind='list', options={'mode': 'include', 'values': ['e1']})],
) %}
{% set pin_t_employees = sigma_data_models.table('employees_cmp', identifier='employees',
  columns=['employee_guid']) %}
{% set pin_spec = sigma_data_models.model(
  name='ID Compare Check',
  tables=[pin_t_accounts, pin_t_employees],
  relationships=[('accounts_cmp', 'account_owner_user_guid', 'employees_cmp', 'employee_guid')],
) %}
{% set pin_acct = pin_spec.pages[0].elements[0] %}
{% set pin_emp  = pin_spec.pages[0].elements[1] %}
{% set pinned_ids = {
  'table:accounts_cmp':                    'd21a84439529e4ee253317068f1c93cb',
  'col:account_guid':                      '9b109847d842f0bffb997720af7a4662',
  'col:account_owner_user_guid':           'c7a88d23afacd355203d877e3131c57a',
  'col:is_named_acme':                     'a3d91ef4d95939d479dfad742397db61',
  'metric:count_accounts':                 'df4c11361dd5b89082b3e42c44c5ee55',
  'folder:Identifiers':                    'afafc4f43cb99fd681d6a9051c0831de',
  'filter:account_owner_user_guid.list':   '3f6b6e4bfeed6da428f17b13477c537e',
  'rel:sourceColumnId':                    'c7a88d23afacd355203d877e3131c57a',
  'rel:targetColumnId':                    '37833e7ccf225f404b538601ffb13b50',
  'rel:targetElementId':                   '4042171a4eb7097424036a4b40e66aa6',
  'table:employees_cmp':                   '4042171a4eb7097424036a4b40e66aa6',
  'col:employee_guid':                     '37833e7ccf225f404b538601ffb13b50',
} %}
{% set pin_actual = {
  'table:accounts_cmp':                    pin_acct.id,
  'col:account_guid':                      pin_acct.columns[0].id,
  'col:account_owner_user_guid':           pin_acct.columns[1].id,
  'col:is_named_acme':                     pin_acct.columns[2].id,
  'metric:count_accounts':                 pin_acct.metrics[0].id,
  'folder:Identifiers':                    pin_acct.folders[0].id,
  'filter:account_owner_user_guid.list':   pin_acct.filters[0].id,
  'rel:sourceColumnId':                    pin_acct.relationships[0]['keys'][0].sourceColumnId,
  'rel:targetColumnId':                    pin_acct.relationships[0]['keys'][0].targetColumnId,
  'rel:targetElementId':                   pin_acct.relationships[0].targetElementId,
  'table:employees_cmp':                   pin_emp.id,
  'col:employee_guid':                     pin_emp.columns[0].id,
} %}
{% for key, expected in pinned_ids.items() %}
  {% if pin_actual[key] != expected %}
    {% do exceptions.raise_compiler_error(
      'assert_sigma_spec: frozen id regression — ' ~ key ~ ' changed from pinned value ' ~
      expected ~ ' (origin/main) to ' ~ pin_actual[key] ~ '. This means freeze_id(), ' ~
      'freeze_scope, or a resolution helper changed a value that was stable on main.'
    ) %}
  {% endif %}
{% endfor %}

{# freeze_id determinism: identical inputs must yield identical ids across independent calls. #}
{% set model_spec_again = sigma_data_models.model(
  name='Shape Check',
  tables=[
    sigma_data_models.table('accounts_shape_check', identifier='accounts', columns=['account_guid', 'account_owner_user_guid']),
    sigma_data_models.table('employees_shape_check', identifier='employees', columns=['employee_guid']),
  ],
  relationships=[('accounts_shape_check', 'account_owner_user_guid', 'employees_shape_check', 'employee_guid')],
) %}
{% if model_spec_again.pages[0].elements[0].id != accounts_element.id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: table element ids are not deterministic across identical calls') %}
{% endif %}
{% if model_spec_again.pages[0].elements[0].columns[0].id != passthrough_column.id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: column ids are not deterministic across identical calls') %}
{% endif %}

{# Control id determinism: same name must always produce the same frozen id. #}
{% set model_spec_control_again = sigma_data_models.model(
  name='Shape Check',
  tables=[
    sigma_data_models.table('accounts_shape_check', identifier='accounts',
      columns=['account_guid', 'account_owner_user_guid']),
    sigma_data_models.table('employees_shape_check', identifier='employees',
      columns=['employee_guid']),
  ],
  controls=[sigma_data_models.control('owner_filter', type='list',
    targets=[('accounts_shape_check', 'account_owner_user_guid')],
    display_name='Account Owner')],
) %}
{% if model_spec_control_again.pages[0].elements[2].id != control_element.id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: control element ids are not deterministic across identical calls') %}
{% endif %}

{# Leaving `columns` empty auto-populates passthrough columns from the live relation - only
   possible under `dbt run-operation`/`dbt run`/`dbt compile` (execute=True), never `dbt parse`. #}
{% set auto_populated_table = sigma_data_models.table('accounts_auto_populate_check', identifier='accounts') %}
{% if auto_populated_table.columns | length == 0 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: leaving columns empty must auto-populate from the live relation, got none') %}
{% endif %}
{% set auto_populated_names = auto_populated_table._column_ids.keys() | list %}
{% if 'account_guid' not in auto_populated_names or 'account_owner_user_guid' not in auto_populated_names %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: auto-populated columns must include the real columns on the relation, got ' ~ auto_populated_names) %}
{% endif %}
{% if auto_populated_table.columns[0].keys() | list | sort != ['formula', 'id'] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: an auto-populated column must still be a plain passthrough column ({id, formula}), got ' ~ (auto_populated_table.columns[0].keys() | list)) %}
{% endif %}

{# Duplicate `key`s across different sigma.table() calls must not collide on element_id -
   `key` is a local wiring label, ids are frozen off the physical identifier instead. #}
{% set table_a = sigma_data_models.table('shared_key', identifier='accounts', columns=['account_guid']) %}
{% set table_b = sigma_data_models.table('shared_key', identifier='employees', columns=['employee_guid']) %}
{% if table_a.id == table_b.id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: tables sharing a key but bound to different identifiers must not collide on element id') %}
{% endif %}

{# element ids are frozen off a lowercased identifier path (and `key`, held constant here), so
   the same key/physical-table pair must still freeze to the same id regardless of db/schema
   casing. #}
{% set table_casing_lower = sigma_data_models.table('casing_check', identifier='accounts', schema='main', columns=['account_guid']) %}
{% set table_casing_upper = sigma_data_models.table('casing_check', identifier='ACCOUNTS', schema='MAIN', columns=['account_guid']) %}
{% if table_casing_lower.id != table_casing_upper.id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: the same key/physical table must freeze to the same id regardless of db/schema/identifier casing') %}
{% endif %}

{# self-joins: the same physical table referenced twice under different `key`s in one model
   must get distinct ids everywhere (table, and its columns), not collide. #}
{% set self_join_spec = sigma_data_models.model(
  name='Self Join Check',
  tables=[
    sigma_data_models.table('employees_self_join', identifier='employees', columns=['employee_guid']),
    sigma_data_models.table('managers_self_join', identifier='employees', columns=['employee_guid']),
  ],
) %}
{% set self_join_elements = self_join_spec.pages[0].elements %}
{% if self_join_elements[0].id == self_join_elements[1].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: the same physical table referenced twice under different keys (a self-join) must not collide on element id') %}
{% endif %}
{% if self_join_elements[0].columns[0].id == self_join_elements[1].columns[0].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a self-joined table\'s columns must not collide on id either') %}
{% endif %}

{# Multi-page: tables with page= set must appear on separate pages in first-appearance order;
   tables with no page= default to the first page (named by page_name or model name). #}
{% set multi_page_spec = sigma_data_models.model(
  name='Multi Page Check',
  tables=[
    sigma_data_models.table('accounts_page_check', identifier='accounts',
      columns=['account_guid', 'account_owner_user_guid'],
      page='Core'),
    sigma_data_models.table('employees_page_check', identifier='employees',
      columns=['employee_guid'],
      page='Extensions'),
  ],
  relationships=[('accounts_page_check', 'account_owner_user_guid', 'employees_page_check', 'employee_guid')],
) %}
{% if multi_page_spec.pages | length != 2 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: tables with distinct page= values must produce one page per unique page name') %}
{% endif %}
{% if multi_page_spec.pages[0].name != 'Core' or multi_page_spec.pages[1].name != 'Extensions' %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: pages must be emitted in first-appearance order of page= values') %}
{% endif %}
{% if multi_page_spec.pages[0].elements | length != 1 or multi_page_spec.pages[1].elements | length != 1 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: each table must appear on its assigned page only') %}
{% endif %}
{% if not multi_page_spec.pages[0].id or not multi_page_spec.pages[1].id or multi_page_spec.pages[0].id == multi_page_spec.pages[1].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: every page must have a non-empty, distinct id') %}
{% endif %}
{% if multi_page_spec.pages[0].id != sigma_data_models.model(name='Multi Page Check', tables=[sigma_data_models.table('x', identifier='accounts', columns=['account_guid'], page='Core')]).pages[0].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: a page id must depend only on its name, so it is stable across recompiles and other model changes') %}
{% endif %}
{# Cross-page relationship: resolves correctly even when source and target are on different pages. #}
{% if 'relationships' not in multi_page_spec.pages[0].elements[0] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: cross-page relationship must still nest under the source (from) table element') %}
{% endif %}
{% if multi_page_spec.pages[0].elements[0].relationships[0].targetElementId != multi_page_spec.pages[1].elements[0].id %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: cross-page relationship.targetElementId must be the target element id, even when on a different page') %}
{% endif %}

{# Default page: tables without page= land on a page named page_name or model name. #}
{% set default_page_spec = sigma_data_models.model(
  name='Default Page Check',
  page_name='My Page',
  tables=[
    sigma_data_models.table('accounts_default_page', identifier='accounts', columns=['account_guid']),
  ],
) %}
{% if default_page_spec.pages | length != 1 or default_page_spec.pages[0].name != 'My Page' %}
  {% do exceptions.raise_compiler_error("assert_sigma_spec: tables without page= must default to page_name (or model name when page_name is unset)") %}
{% endif %}

{# Connection tags: model() stores them as _connection_tags in the returned dict; materialize()
   splits them into meta.sigma_data_model_connection_tags, leaving meta.sigma_data_model unchanged. #}
{% set tagged_spec = sigma_data_models.model(
  name='Connection Tags Check',
  tables=[
    sigma_data_models.table('tagged_accounts', identifier='accounts',
      connection_id='conn-primary',
      columns=['account_guid']),
  ],
  connection_tags=[
    {'name': 'Canada', 'connection_id': 'conn-canada'},
    {'name': 'EU',     'connection_id': 'conn-eu'},
  ],
) %}
{% if tagged_spec._connection_tags | length != 2 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: model() must store connection_tags as _connection_tags on the returned dict') %}
{% endif %}
{% if tagged_spec._connection_tags[0].name != 'Canada' or tagged_spec._connection_tags[0].connectionId != 'conn-canada' %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: _connection_tags[0] must have name=Canada and connectionId=conn-canada') %}
{% endif %}
{% if tagged_spec._connection_tags[1].name != 'EU' or tagged_spec._connection_tags[1].connectionId != 'conn-eu' %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: _connection_tags[1] must have name=EU and connectionId=conn-eu') %}
{% endif %}
{% if '_connection_tags' in tagged_spec.pages[0] %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: _connection_tags must not appear in page output') %}
{% endif %}
{% set untagged_spec = sigma_data_models.model(
  name='No Connection Tags Check',
  tables=[sigma_data_models.table('untagged_accounts', identifier='accounts', columns=['account_guid'])],
) %}
{% if untagged_spec._connection_tags | length != 0 %}
  {% do exceptions.raise_compiler_error('assert_sigma_spec: model with no connection_tags must have empty _connection_tags list') %}
{% endif %}

{{ log('assert_sigma_spec: all assertions passed', info=true) }}
{% endmacro %}

{# Expected to fail: calling code should invoke these via `dbt run-operation` and treat a
   nonzero exit as success - a zero exit means the corresponding guard regressed. #}

{% macro assert_duplicate_column_rejected() %}
{% do sigma_data_models.table('dup_columns_check', identifier='accounts', columns=['account_guid', 'account_guid']) %}
{% endmacro %}

{% macro assert_duplicate_metric_rejected() %}
{% do sigma_data_models.table('dup_metrics_check', identifier='accounts', columns=['account_guid'], metrics=[
  sigma_data_models.metric('count_accounts', 'CountDistinct([Account Guid])'),
  sigma_data_models.metric('count_accounts', 'Count([Account Guid])'),
]) %}
{% endmacro %}

{% macro assert_duplicate_table_key_rejected() %}
{% do sigma_data_models.model(
  name='Duplicate Table Key Check',
  tables=[
    sigma_data_models.table('dup_key', identifier='accounts', columns=['account_guid']),
    sigma_data_models.table('dup_key', identifier='employees', columns=['employee_guid']),
  ],
) %}
{% endmacro %}

{% macro assert_unknown_relationship_from_rejected() %}
{% do sigma_data_models.model(
  name='Unknown Relationship From Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid'])],
  relationships=[('nonexistent_key', 'account_guid', 'accounts', 'account_guid')],
) %}
{% endmacro %}

{% macro assert_unknown_relationship_to_rejected() %}
{% do sigma_data_models.model(
  name='Unknown Relationship To Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid'])],
  relationships=[('accounts', 'account_guid', 'nonexistent_key', 'account_guid')],
) %}
{% endmacro %}

{% macro assert_unknown_relationship_column_rejected() %}
{% do sigma_data_models.model(
  name='Unknown Relationship Column Check',
  tables=[
    sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid']),
    sigma_data_models.table('employees', identifier='employees', columns=['employee_guid']),
  ],
  relationships=[('accounts', 'not_a_real_column', 'employees', 'employee_guid')],
) %}
{% endmacro %}

{% macro assert_unknown_folder_column_rejected() %}
{% do sigma_data_models.table('bad_folder_check', identifier='accounts', columns=['account_guid'],
  folders=[sigma_data_models.folder('Identifiers', columns=['not_a_real_column'])]) %}
{% endmacro %}

{% macro assert_unknown_folder_metric_rejected() %}
{% do sigma_data_models.table('bad_folder_metric_check', identifier='accounts', columns=['account_guid'],
  metrics=[sigma_data_models.metric('count_accounts', 'CountDistinct([Account Guid])')],
  folders=[sigma_data_models.folder('Metrics', metrics=['not_a_real_metric'])]) %}
{% endmacro %}

{% macro assert_unknown_filter_column_rejected() %}
{% do sigma_data_models.table('bad_filter_check', identifier='accounts', columns=['account_guid'],
  filters=[sigma_data_models.filter('not_a_real_column', kind='list', options={'mode': 'include', 'values': ['x']})]) %}
{% endmacro %}

{% macro assert_nonexistent_relation_rejected() %}
{% do sigma_data_models.table('typo_check', identifier='accounts_typo') %}
{% endmacro %}

{% macro assert_duplicate_folder_rejected() %}
{% do sigma_data_models.table('dup_folder_check', identifier='accounts', columns=['account_guid', 'account_owner_user_guid'],
  folders=[
    sigma_data_models.folder('Identifiers', columns=['account_guid']),
    sigma_data_models.folder('Identifiers', columns=['account_owner_user_guid']),
  ]) %}
{% endmacro %}

{% macro assert_duplicate_filter_rejected() %}
{% do sigma_data_models.table('dup_filter_check', identifier='accounts', columns=['account_guid'],
  filters=[
    sigma_data_models.filter('account_guid', kind='list', options={'mode': 'include', 'values': ['a1']}),
    sigma_data_models.filter('account_guid', kind='list', options={'mode': 'exclude', 'values': ['a2']}),
  ]) %}
{% endmacro %}

{% macro assert_duplicate_relationship_rejected() %}
{% do sigma_data_models.model(
  name='Duplicate Relationship Check',
  tables=[
    sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid', 'account_owner_user_guid']),
    sigma_data_models.table('employees', identifier='employees', columns=['employee_guid']),
  ],
  relationships=[
    ('accounts', 'account_owner_user_guid', 'employees', 'employee_guid'),
    ('accounts', 'account_owner_user_guid', 'employees', 'employee_guid'),
  ],
) %}
{% endmacro %}

{% macro assert_filter_options_reserved_key_rejected() %}
{% do sigma_data_models.table('filter_reserved_key_check', identifier='accounts', columns=['account_guid'],
  filters=[sigma_data_models.filter('account_guid', kind='list', options={'kind': 'CLOBBERED'})]) %}
{% endmacro %}

{% macro assert_alphanumeric_column_rejected() %}
{% do sigma_data_models.table('alphanumeric_column_check', identifier='accounts', columns=['active_paid_users_l30_days']) %}
{% endmacro %}

{% macro assert_digit_token_column_rejected() %}
{% do sigma_data_models.table('digit_token_column_check', identifier='accounts', columns=['revenue_2023']) %}
{% endmacro %}

{% macro assert_unsupported_format_kind_rejected() %}
{% do sigma_data_models.format('percent') %}
{% endmacro %}

{% macro assert_unsupported_number_format_option_rejected() %}
{% do sigma_data_models.format('number', {'unknownField': 'value'}) %}
{% endmacro %}

{% macro assert_unsupported_datetime_format_option_rejected() %}
{% do sigma_data_models.format('datetime', {'currencySymbol': '$'}) %}
{% endmacro %}

{% macro assert_duplicate_control_rejected() %}
{% do sigma_data_models.model(
  name='Duplicate Control Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid'])],
  controls=[
    sigma_data_models.control('dup_filter', type='list', targets=[('accounts', 'account_guid')]),
    sigma_data_models.control('dup_filter', type='list', targets=[('accounts', 'account_guid')]),
  ],
) %}
{% endmacro %}

{% macro assert_empty_control_targets_rejected() %}
{% do sigma_data_models.model(
  name='Empty Control Targets Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid'])],
  controls=[sigma_data_models.control('empty_targets', type='list', targets=[])],
) %}
{% endmacro %}

{% macro assert_unknown_control_table_rejected() %}
{% do sigma_data_models.model(
  name='Unknown Control Table Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid'])],
  controls=[sigma_data_models.control('bad_table_filter', type='list', targets=[('nonexistent_key', 'account_guid')])],
) %}
{% endmacro %}

{% macro assert_unknown_control_column_rejected() %}
{% do sigma_data_models.model(
  name='Unknown Control Column Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid'])],
  controls=[sigma_data_models.control('bad_col_filter', type='list', targets=[('accounts', 'not_a_real_column')])],
) %}
{% endmacro %}

{% macro assert_control_options_reserved_key_rejected() %}
{% do sigma_data_models.model(
  name='Control Options Reserved Key Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid'])],
  controls=[sigma_data_models.control('reserved_key_filter', type='list',
    targets=[('accounts', 'account_guid')], options={'id': 'CLOBBERED'})],
) %}
{% endmacro %}

{% macro assert_duplicate_connection_tag_rejected() %}
{% do sigma_data_models.model(
  name='Duplicate Connection Tag Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid'])],
  connection_tags=[
    {'name': 'dup', 'connection_id': 'conn-a'},
    {'name': 'dup', 'connection_id': 'conn-b'},
  ],
) %}
{% endmacro %}

{% macro assert_missing_connection_tag_connection_id_rejected() %}
{% do sigma_data_models.model(
  name='Missing Connection Tag Connection Id Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', columns=['account_guid'])],
  connection_tags=[{'name': 'Bad Tag'}],
) %}
{% endmacro %}

{% macro assert_bad_connection_tag_from_connection_id_rejected() %}
{% do sigma_data_models.model(
  name='Bad Connection Tag From Connection Id Check',
  tables=[sigma_data_models.table('accounts', identifier='accounts', connection_id='conn-real', columns=['account_guid'])],
  connection_tags=[{'name': 'EU', 'connection_id': 'conn-eu',
         'paths': [{'from_connection_id': 'conn-nonexistent'}]}],
) %}
{% endmacro %}
