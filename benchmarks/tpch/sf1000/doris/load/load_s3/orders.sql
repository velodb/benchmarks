LOAD LABEL orders_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpch/sf1000/orders/orders.tbl.*")
    INTO TABLE orders
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (o_orderkey, o_custkey, o_orderstatus, o_totalprice, o_orderdate, o_orderpriority, o_clerk, o_shippriority, o_comment)
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
