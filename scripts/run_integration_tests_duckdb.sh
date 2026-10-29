#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INT_TESTS_DIR="$REPO_ROOT/integration_tests"

echo "=== dbt-sigma-data-models Integration Tests (DuckDB) ==="
echo ""

mkdir -p "$REPO_ROOT/duckdb"

cd "$INT_TESTS_DIR"

echo "1. Installing dependencies..."
dbt deps --profile sigma_integration_tests_duckdb

echo ""
echo "2. Loading seed data..."
dbt seed --profile sigma_integration_tests_duckdb

echo ""
echo "3. Running dbt models..."
dbt run --profile sigma_integration_tests_duckdb

echo ""
echo "4. Parsing to verify the compiled Sigma spec (no partial parse)..."
dbt parse --profile sigma_integration_tests_duckdb --no-partial-parse

echo ""
echo "5. Asserting on the shape of composed specs..."
dbt run-operation assert_sigma_spec --profile sigma_integration_tests_duckdb

echo ""
echo "6. Asserting invalid inputs are rejected..."
NEGATIVE_MACROS="assert_duplicate_column_rejected assert_duplicate_metric_rejected assert_duplicate_table_key_rejected assert_unknown_relationship_from_rejected assert_unknown_relationship_to_rejected assert_unknown_relationship_column_rejected assert_unknown_folder_column_rejected assert_unknown_folder_metric_rejected assert_unknown_filter_column_rejected assert_nonexistent_relation_rejected assert_duplicate_folder_rejected assert_duplicate_filter_rejected assert_duplicate_relationship_rejected assert_filter_options_reserved_key_rejected assert_alphanumeric_column_rejected assert_digit_token_column_rejected assert_unsupported_format_kind_rejected assert_unsupported_number_format_option_rejected assert_unsupported_datetime_format_option_rejected assert_duplicate_control_rejected assert_empty_control_targets_rejected assert_unknown_control_table_rejected assert_unknown_control_column_rejected assert_control_options_reserved_key_rejected assert_duplicate_connection_tag_rejected assert_missing_connection_tag_connection_id_rejected assert_bad_connection_tag_from_connection_id_rejected assert_empty_connection_tag_name_rejected assert_empty_connection_tag_path_rejected assert_overlong_connection_tag_path_rejected assert_nonstring_connection_tag_path_rejected assert_unpaired_connection_tag_path_rejected assert_duplicate_connection_tag_from_path_rejected assert_conflicting_connection_tag_connection_id_rejected assert_connection_tag_paths_bad_table_rejected"
for macro in $NEGATIVE_MACROS; do
  set +e
  dbt run-operation "$macro" --profile sigma_integration_tests_duckdb > /tmp/sigma_negative_check.log 2>&1
  NEGATIVE_EXIT=$?
  set -e
  if [ $NEGATIVE_EXIT -eq 0 ]; then
    echo "Expected $macro to raise a compiler error, but it compiled successfully:"
    cat /tmp/sigma_negative_check.log
    exit 1
  fi
  echo "$macro was correctly rejected."
done

echo ""
echo "=== All tests passed! ==="
