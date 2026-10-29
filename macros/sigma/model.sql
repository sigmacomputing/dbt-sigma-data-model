{% macro model(name, tables, relationships=[], controls=[], page_name=none, folder_id=none, data_model_id=none, connection_tags=[]) %}
{% set table_keys = [] %}
{% set table_by_key = {} %}
{% for t in tables %}
  {% if t.key in table_keys %}
    {% do exceptions.raise_compiler_error("sigma_data_models.model('" ~ name ~ "'): duplicate table key '" ~ t.key ~ "' - table keys must be unique within a single model, since relationships resolve `from`/`to` against them.") %}
  {% endif %}
  {% do table_keys.append(t.key) %}
  {% do table_by_key.update({t.key: t}) %}
{% endfor %}

{# Relationships nest inside their source table's element in Sigma's schema (not at the
   model level), and reference the target table by its real element id - both of which are
   only knowable once every table in this call has been composed, so resolution happens here
   rather than in sigma_data_models.relationship() itself. Relationships resolve against all
   tables globally regardless of which page each table is assigned to, so cross-page
   relationships work transparently. #}
{% set relationship_keys = [] %}
{% for rel in relationships %}
  {% set rel = sigma_data_models.relationship(*rel) if rel is sequence and rel is not mapping and rel is not string else rel %}
  {% set ctx = "sigma_data_models.model('" ~ name ~ "'): relationship" %}
  {% set source_table = sigma_data_models._resolve_table(ctx ~ " `from`", rel.from, table_by_key) %}
  {% set target_table = sigma_data_models._resolve_table(ctx ~ " `to`", rel.to, table_by_key) %}
  {% set source_col_id = sigma_data_models._resolve_column_id(ctx, rel.from, source_table, rel.from_column) %}
  {% set target_col_id = sigma_data_models._resolve_column_id(ctx, rel.to, target_table, rel.to_column) %}
  {% set relationship_key = rel.from ~ '_to_' ~ rel.to ~ '_' ~ rel.from_column ~ '_' ~ rel.to_column %}
  {% if relationship_key in relationship_keys %}
    {% do exceptions.raise_compiler_error("sigma_data_models.model('" ~ name ~ "'): duplicate relationship '" ~ relationship_key ~ "' - the same from/from_column/to/to_column combination was passed more than once.") %}
  {% endif %}
  {% do relationship_keys.append(relationship_key) %}
  {% set relationship_entry = {
    "id": sigma_data_models.freeze_id('relationship:' ~ relationship_key),
    "targetElementId": target_table.id,
    "keys": [{
      "sourceColumnId": source_col_id,
      "targetColumnId": target_col_id,
    }],
    "name": rel.name or (sigma_data_models.titleize(rel.from) ~ ' → ' ~ sigma_data_models.titleize(rel.to)),
  } %}
  {% if 'relationships' not in source_table %}
    {% do source_table.update({"relationships": []}) %}
  {% endif %}
  {% do source_table.relationships.append(relationship_entry) %}
{% endfor %}

{# Controls are page-level elements (siblings to table elements) that filter one or more
   table columns. Resolution happens here rather than in sigma_data_models.control() since it
   requires table_by_key lookups. Each target in targets=[] is a (table_key, column_name)
   pair that resolves to (elementId, columnId) in the emitted filters array. #}
{% set control_names = [] %}
{% set frozen_controls = [] %}
{% for control in controls %}
  {% if control.name in control_names %}
    {% do exceptions.raise_compiler_error("sigma_data_models.model('" ~ name ~ "'): duplicate control name '" ~ control.name ~ "' - control names must be unique within a model.") %}
  {% endif %}
  {% do control_names.append(control.name) %}
  {% if not control.targets %}
    {% do exceptions.raise_compiler_error("sigma_data_models.model('" ~ name ~ "'): control '" ~ control.name ~ "' has no targets - supply at least one (table_key, column_name) pair in targets=[...].") %}
  {% endif %}
  {% for reserved_key in ['id', 'controlId', 'controlType', 'kind', 'filters'] %}
    {% if reserved_key in control.options %}
      {% do exceptions.raise_compiler_error("sigma_data_models.model('" ~ name ~ "'): control '" ~ control.name ~ "' options can't set '" ~ reserved_key ~ "' - it's already set from name/type/targets and would silently overwrite the frozen value.") %}
    {% endif %}
  {% endfor %}
  {% set frozen_filters = [] %}
  {% set ns = namespace(first_target_page=none) %}
  {% set ctx = "sigma_data_models.model('" ~ name ~ "'): control '" ~ control.name ~ "'" %}
  {% for target in control.targets %}
    {% set target_table = sigma_data_models._resolve_table(ctx, target[0], table_by_key) %}
    {% set target_col_id = sigma_data_models._resolve_column_id(ctx, target[0], target_table, target[1]) %}
    {% if loop.first %}
      {% set ns.first_target_page = target_table._page %}
    {% endif %}
    {% do frozen_filters.append({
      "source": {"kind": "table", "elementId": target_table.id},
      "columnId": target_col_id,
    }) %}
  {% endfor %}
  {% set frozen_control = {
    "kind": "control",
    "id": sigma_data_models.freeze_id('control:' ~ control.name),
    "controlId": control.name,
    "controlType": control.type,
    "name": control.display_name or sigma_data_models.titleize(control.name),
    "filters": frozen_filters,
    "_page": control._page or ns.first_target_page,
  } %}
  {% do frozen_control.update(control.options) %}
  {% do frozen_controls.append(frozen_control) %}
{% endfor %}

{# Collect all connectionIds used by tables, for validating connection_tag paths.from_connection_id. #}
{% set table_connection_ids = [] %}
{% for t in tables %}
  {% if t.source.connectionId not in table_connection_ids %}
    {% do table_connection_ids.append(t.source.connectionId) %}
  {% endif %}
{% endfor %}

{# Validate and normalize connection tags. Each tag maps the model's primary connection to a new
   connection_id, so a sync tool can call POST /v2/dataModels/tag with sourceMappingConfig.
   Tags are stored as _connection_tags in the returned dict and extracted by materialize() into
   the separate meta.sigma_data_model_connection_tags key, leaving the spec itself unchanged. #}
{% set frozen_connection_tags = sigma_data_models.validate_connection_tags(name, connection_tags, table_connection_ids) %}

{# Group tables into pages by their _page field, in first-appearance order. Tables with no
   _page set land on the default page, named by page_name (falling back to name). When all
   tables omit _page the output is a single page, identical to the previous single-page
   behaviour. #}
{% set default_page_name = page_name or name %}
{% set page_order = [] %}
{% set tables_by_page = {} %}
{% for t in tables %}
  {% set pname = t._page or default_page_name %}
  {% if pname not in page_order %}
    {% do page_order.append(pname) %}
    {% do tables_by_page.update({pname: []}) %}
  {% endif %}
  {% do tables_by_page[pname].append(t) %}
{% endfor %}

{# Group controls into the same page structure. Controls without an explicit page= inherit
   the page of their first target table. A control whose target table has no page= lands on
   the default page, same as the table. #}
{% set controls_by_page = {} %}
{% for c in frozen_controls %}
  {% set pname = c._page or default_page_name %}
  {% if pname not in page_order %}
    {% do page_order.append(pname) %}
  {% endif %}
  {% if pname not in controls_by_page %}
    {% do controls_by_page.update({pname: []}) %}
  {% endif %}
  {% do controls_by_page[pname].append(c) %}
{% endfor %}

{# Strip internal-only fields (`key`, `_column_ids`, `_page`) before emitting - none are real
   fields in Sigma's schema, they only exist to resolve relationships/folders/page grouping. #}
{% set output_pages = [] %}
{% for pname in page_order %}
  {% set elements = [] %}
  {% for t in (tables_by_page[pname] if pname in tables_by_page else []) %}
    {% set clean_element = {} %}
    {% for field_name, field_value in t.items() %}
      {% if not field_name.startswith('_') and field_name != 'key' %}
        {% do clean_element.update({field_name: field_value}) %}
      {% endif %}
    {% endfor %}
    {% do elements.append(clean_element) %}
  {% endfor %}
  {% for c in (controls_by_page[pname] if pname in controls_by_page else []) %}
    {% set clean_control = {} %}
    {% for field_name, field_value in c.items() %}
      {% if not field_name.startswith('_') %}
        {% do clean_control.update({field_name: field_value}) %}
      {% endif %}
    {% endfor %}
    {% do elements.append(clean_control) %}
  {% endfor %}
  {% do output_pages.append({
    "id": "",
    "name": pname,
    "elements": elements,
  }) %}
{% endfor %}

{% do return({
  "dataModelId": data_model_id,
  "name": name,
  "folderId": folder_id or var('sigma_folder_id', none),
  "schemaVersion": 1,
  "pages": output_pages,
  "_connection_tags": frozen_connection_tags,
}) %}
{% endmacro %}
