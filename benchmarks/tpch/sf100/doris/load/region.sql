INSERT INTO region (r_regionkey, r_name, r_comment) SELECT c1, c2, c3 FROM S3(
    "uri" = "s3://${STORAGE_BUCKET}/tpch/sf100/region.tbl",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|",
    "skip_lines" = "0"
);