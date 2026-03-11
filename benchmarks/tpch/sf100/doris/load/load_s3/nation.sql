LOAD LABEL nation_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpch/sf100/nation/nation.tbl")
    INTO TABLE nation
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (n_nationkey, n_name, n_regionkey, n_comment)
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
