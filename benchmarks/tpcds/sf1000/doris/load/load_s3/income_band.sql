LOAD LABEL income_band_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpcds/sf1000/income_band/income_band*.*")
    INTO TABLE income_band
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (ib_income_band_sk, ib_lower_bound, ib_upper_bound)
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
