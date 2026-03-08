INSERT INTO orders (o_orderkey, o_custkey, o_orderstatus, o_totalprice, o_orderdate, o_orderpriority, o_clerk, o_shippriority, o_comment) SELECT c1, c2, c3, c4, c5, c6, c7, c8, c9 FROM S3(
    "uri" = "s3://${STORAGE_BUCKET}/tpch/sf100/orders/orders.tbl.*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|",
    "skip_lines" = "0"
);