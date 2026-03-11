LOAD LABEL ship_mode_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpcds/sf1000/ship_mode/ship_mode*.*")
    INTO TABLE ship_mode
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (sm_ship_mode_sk, sm_ship_mode_id, sm_type, sm_code, sm_carrier, sm_contract)
)
WITH S3
(
    "AWS_ENDPOINT" = "${STORAGE_ENDPOINT}",
    "AWS_REGION" = "${STORAGE_REGION}",
    "use_path_style" = "false"
)
PROPERTIES
(
    "timeout" = "36000",
    "load_parallelism" = "8",
    "max_filter_ratio" = "0.1"
);
