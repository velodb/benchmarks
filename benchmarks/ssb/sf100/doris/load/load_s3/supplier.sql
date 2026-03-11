LOAD LABEL supplier_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/ssb/sf100/supplier/supplier.tbl.gz")
    INTO TABLE supplier
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (s_suppkey,s_name,s_address,s_city,s_nation,s_region,s_phone)
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
