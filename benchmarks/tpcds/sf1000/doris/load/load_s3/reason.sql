LOAD LABEL reason_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpcds/sf1000/reason/reason*.*")
    INTO TABLE reason
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (r_reason_sk, r_reason_id, r_reason_desc)
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
