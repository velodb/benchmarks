INSERT INTO lineitem (
    l_orderkey, l_partkey, l_suppkey, l_linenumber, l_quantity, l_extendedprice, l_discount, l_tax, l_returnflag,l_linestatus, l_shipdate,l_commitdate,l_receiptdate,l_shipinstruct,l_shipmode,l_comment
)
SELECT l_orderkey, l_partkey, l_suppkey, l_linenumber, l_quantity, l_extendedprice, l_discount, l_tax, l_returnflag,l_linestatus, l_shipdate,l_commitdate,l_receiptdate,l_shipinstruct,l_shipmode,l_comment FROM S3 (
        "uri" = "s3://${STORAGE_BUCKET}/tpch/sf100/*",
        "s3.endpoint" = "${STORAGE_ENDPOINT}",
        "s3.region" = "${STORAGE_REGION}",
        "column_separator" = "|",
        FORMAT = "CSV",
        csv_schema = "l_orderkey:bigint;l_partkey:int;l_suppkey:int;l_linenumber:int;l_quantity:decimal(15, 2);l_extendedprice:decimal(15, 2);l_discount:decimal(15, 2);l_tax:decimal(15, 2);l_returnflag:STRING;l_linestatus:STRING;l_shipdate:DATE;l_commitdate:DATE;l_receiptdate:DATE;l_shipinstruct:STRING;l_shipmode:STRING;l_comment:STRING"
);