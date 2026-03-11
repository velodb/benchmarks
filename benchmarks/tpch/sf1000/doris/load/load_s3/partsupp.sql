LOAD LABEL partsupp_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpch/sf1000/partsupp/partsupp.tbl.*")
    INTO TABLE partsupp
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (ps_partkey, ps_suppkey, ps_availqty, ps_supplycost, ps_comment)
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
