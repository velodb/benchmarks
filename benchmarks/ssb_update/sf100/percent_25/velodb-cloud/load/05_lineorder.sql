INSERT INTO lineorder (
    lo_orderkey,lo_linenumber,lo_custkey,lo_partkey,lo_suppkey,lo_orderdate,lo_orderpriority,lo_shippriority,lo_quantity,lo_extendedprice,lo_ordtotalprice,lo_discount,lo_revenue,lo_supplycost,lo_tax,lo_commitdate,lo_shipmode
) SELECT * FROM S3 (
        "uri" = "s3://${STORAGE_BUCKET}/ssb/sf100/lineorder/*",
        "format" = "csv",
        "s3.endpoint" = "${STORAGE_ENDPOINT}",
        "s3.region" = "${STORAGE_REGION}",
        "column_separator" = "|",
        csv_schema = "lo_orderkey:int;lo_linenumber:int;lo_custkey:int;lo_partkey:int;lo_suppkey:int;lo_orderdate:int;lo_orderpriority:string;lo_shippriority:int;lo_quantity:int;lo_extendedprice:int;lo_ordtotalprice:int;lo_discount:int;lo_revenue:int;lo_supplycost:int;lo_tax:int;lo_commitdate:int;lo_shipmode:STRING",
        "compress_type"="gz"
);
