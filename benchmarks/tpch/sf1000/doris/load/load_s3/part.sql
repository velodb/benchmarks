LOAD LABEL part_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpch/sf1000/part/part.tbl.gz")
    INTO TABLE part
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (p_partkey, p_name, p_mfgr, p_brand, p_type, p_size, p_container, p_retailprice, p_comment)
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
