LOAD LABEL household_demographics_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpcds/sf100/household_demographics/household_demographics*.*")
    INTO TABLE household_demographics
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (hd_demo_sk, hd_income_band_sk, hd_buy_potential, hd_dep_count, hd_vehicle_count)
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
