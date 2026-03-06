INSERT INTO income_band (ib_income_band_sk, ib_lower_bound, ib_upper_bound) SELECT * FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/performance/data/tpcds_sf100/income_band*.*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|"
);

