INSERT INTO partsupp (ps_partkey, ps_suppkey, ps_availqty, ps_supplycost, ps_comment) SELECT c1, c2, c3, c4, c5 FROM S3(
    "uri" = "s3://${STORAGE_BUCKET}/performance/data/tpch_sf100/partsupp.tbl.*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|",
    "skip_lines" = "0"
);