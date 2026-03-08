INSERT INTO ship_mode (sm_ship_mode_sk, sm_ship_mode_id, sm_type, sm_code, sm_carrier, sm_contract) SELECT * FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/tpcds/sf1000/ship_mode/ship_mode*.*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|"
);


