INSERT INTO nation (n_nationkey, n_name, n_regionkey, n_comment) SELECT c1, c2, c3, c4 FROM S3(
    "uri" = "s3://${STORAGE_BUCKET}/tpch/sf1000/nation/*.gz",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|",
    "skip_lines" = "0"
);