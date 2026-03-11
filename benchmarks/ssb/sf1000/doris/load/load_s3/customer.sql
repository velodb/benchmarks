LOAD LABEL customer_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/ssb/sf1000/customer/customer.tbl.gz")
    INTO TABLE customer
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (c_custkey,c_name,c_address,c_city,c_nation,c_region,c_phone,c_mktsegment)
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
