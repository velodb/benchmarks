INSERT INTO part (p_partkey,p_name,p_mfgr,p_category,p_brand,p_color,p_type,p_size,p_container) SELECT c1, c2, c3, c4, c5, c6, c7, c8, c9 FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/ssb/sf1000/part.tbl",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|",
    "skip_lines" = "0"
);