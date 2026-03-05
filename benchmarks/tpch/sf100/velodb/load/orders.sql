INSERT INTO orders (
    o_orderkey, o_custkey, o_orderstatus, o_totalprice, o_orderdate, o_orderpriority, o_clerk, o_shippriority, o_comment
)
SELECT o_orderkey, o_custkey, o_orderstatus, o_totalprice, o_orderdate, o_orderpriority, o_clerk, o_shippriority, o_comment FROM S3 (
        "uri" = "s3://${STORAGE_BUCKET}/tpch/sf100/*",
        "format" = "csv",
        "s3.endpoint" = "${STORAGE_ENDPOINT}",
        "s3.region" = "${STORAGE_REGION}",
        "column_separator" = "|",
        csv_schema = "o_orderkey:bigint;o_custkey:int;o_orderstatus:STRING;o_totalprice:decimal(15, 2);o_orderdate:date;o_orderpriority:STRING;o_clerk:STRING;o_shippriority:INT;o_comment:STRING"
);