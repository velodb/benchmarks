INSERT INTO reason (r_reason_sk, r_reason_id, r_reason_desc) SELECT * FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/tpcds/sf100/reason*.*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|"
);


