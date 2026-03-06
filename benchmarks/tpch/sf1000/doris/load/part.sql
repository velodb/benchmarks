INSERT INTO part (p_partkey, p_name, p_mfgr, p_brand, p_type, p_size, p_container, p_retailprice, p_comment) SELECT c1, c2, c3, c4, c5, c6, c7, c8, c9 FROM S3(
    "uri" = "s3://${STORAGE_BUCKET}/performance/data/tpch_sf1000/part.tbl.gz",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|",
    "skip_lines" = "0"
);