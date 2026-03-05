INSERT INTO household_demographics (hd_demo_sk, hd_income_band_sk, hd_buy_potential, hd_dep_count, hd_vehicle_count) SELECT * FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/tpcds/sf1000/household_demographics/*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|"
);
