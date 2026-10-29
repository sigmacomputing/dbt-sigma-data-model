{# Reads one field off a connection_tag (or path) dict, accepting either the snake_case
   spelling or Sigma's camelCase one. Raises if both are given with different values. #}
{% macro _connection_tag_field(ctx, obj, snake, camel) %}
  {% set snake_value = obj.get(snake) %}
  {% set camel_value = obj.get(camel) %}
  {% if snake_value is not none and camel_value is not none and snake_value != camel_value %}
    {% do exceptions.raise_compiler_error(ctx ~ ": both '" ~ snake ~ "' and '" ~ camel ~ "' were set with different values - use one.") %}
  {% endif %}
  {% do return(snake_value if snake_value is not none else camel_value) %}
{% endmacro %}

{# A path is a list of 1-3 non-empty strings: [database], [database, schema], or
   [database, schema, table]. #}
{% macro _validate_connection_tag_path(ctx, label, value) %}
  {% if value is string or value is not sequence or value is mapping or value | length < 1 or value | length > 3 %}
    {% do exceptions.raise_compiler_error(ctx ~ ": " ~ label ~ " must be a list of 1 to 3 strings ([database], [database, schema] or [database, schema, table]), got " ~ value ~ ".") %}
  {% endif %}
  {% for element in value %}
    {% if element is not string or not element %}
      {% do exceptions.raise_compiler_error(ctx ~ ": " ~ label ~ " elements must be non-empty strings, got " ~ value ~ ".") %}
    {% endif %}
  {% endfor %}
{% endmacro %}

{# Validates connection_tags and normalizes them to the shape emitted in
   meta.sigma_data_model_connection_tags (camelCase, matching the tag API's
   sourceMappingConfig). Called by model(). #}
{% macro validate_connection_tags(model_name, connection_tags, table_connection_ids) %}
  {% set connection_tag_names = [] %}
  {% set frozen_connection_tags = [] %}
  {% for connection_tag in connection_tags %}
    {% set ctx = "sigma_data_models.model('" ~ model_name ~ "')" %}
    {% if not connection_tag.get('name') %}
      {% do exceptions.raise_compiler_error(ctx ~ ": each connection_tag must have a non-empty 'name'.") %}
    {% endif %}
    {% set ctx = ctx ~ ": connection_tag '" ~ connection_tag.name ~ "'" %}
    {% if connection_tag.name in connection_tag_names %}
      {% do exceptions.raise_compiler_error("sigma_data_models.model('" ~ model_name ~ "'): duplicate connection_tag name '" ~ connection_tag.name ~ "' - connection_tag names must be unique within a model.") %}
    {% endif %}
    {% do connection_tag_names.append(connection_tag.name) %}
    {% set tag_connection_id = sigma_data_models._connection_tag_field(ctx, connection_tag, 'connection_id', 'connectionId') %}
    {% if not tag_connection_id %}
      {% do exceptions.raise_compiler_error(ctx ~ " is missing required 'connection_id'.") %}
    {% endif %}
    {% set frozen_connection_tag = {'name': connection_tag.name, 'connectionId': tag_connection_id} %}
    {% if connection_tag.get('paths') is not none %}
      {% set frozen_paths = [] %}
      {% set seen_from_paths = [] %}
      {% for path in connection_tag.paths %}
        {% set path_ctx = ctx ~ " paths[" ~ loop.index0 ~ "]" %}
        {% set from_connection_id = sigma_data_models._connection_tag_field(path_ctx, path, 'from_connection_id', 'fromConnectionId') %}
        {% set from_path = sigma_data_models._connection_tag_field(path_ctx, path, 'from_path', 'fromPath') %}
        {% set to_path = sigma_data_models._connection_tag_field(path_ctx, path, 'to_path', 'toPath') %}
        {% if from_connection_id is not none and from_connection_id not in table_connection_ids %}
          {% do exceptions.raise_compiler_error(path_ctx ~ " references from_connection_id '" ~ from_connection_id ~ "' which no table in this model uses.") %}
        {% endif %}
        {% if (from_path is none) != (to_path is none) %}
          {% do exceptions.raise_compiler_error(path_ctx ~ " must set both 'from_path' and 'to_path', or neither.") %}
        {% endif %}
        {% set fp = {} %}
        {% if from_connection_id is not none %}{% do fp.update({'fromConnectionId': from_connection_id}) %}{% endif %}
        {% if from_path is not none %}
          {% do sigma_data_models._validate_connection_tag_path(path_ctx, 'from_path', from_path) %}
          {% do sigma_data_models._validate_connection_tag_path(path_ctx, 'to_path', to_path) %}
          {% set from_path_key = (from_connection_id or '') ~ '|' ~ from_path | join('/') %}
          {% if from_path_key in seen_from_paths %}
            {% do exceptions.raise_compiler_error(path_ctx ~ " duplicates an earlier from_path " ~ from_path ~ " - a from_path may appear only once per connection_tag.") %}
          {% endif %}
          {% do seen_from_paths.append(from_path_key) %}
          {% do fp.update({'fromPath': from_path, 'toPath': to_path}) %}
        {% endif %}
        {% do frozen_paths.append(fp) %}
      {% endfor %}
      {% do frozen_connection_tag.update({'paths': frozen_paths}) %}
    {% endif %}
    {% do frozen_connection_tags.append(frozen_connection_tag) %}
  {% endfor %}
  {% do return(frozen_connection_tags) %}
{% endmacro %}

{# Maps each table's own [database, schema, table] path to a table-level path on the tagged
   connection, so a tag doesn't need one hand-written `paths` entry per table. to_database /
   to_schema override the corresponding path element; the table name is kept. Concatenate calls
   to map different table groups to different databases or schemas. #}
{% macro connection_tag_paths(tables, to_database=none, to_schema=none) %}
  {% set paths = [] %}
  {% for t in tables %}
    {% set source_path = t.source.path if t.source is defined and t.source.path is defined else none %}
    {% if source_path is none or source_path | length != 3 %}
      {% do exceptions.raise_compiler_error("sigma_data_models.connection_tag_paths: table '" ~ t.get('key', t.get('name')) ~ "' has no 3-element [database, schema, table] source.path.") %}
    {% endif %}
    {% do paths.append({
      'from_path': source_path,
      'to_path': [to_database or source_path[0], to_schema or source_path[1], source_path[2]],
    }) %}
  {% endfor %}
  {% do return(paths) %}
{% endmacro %}
