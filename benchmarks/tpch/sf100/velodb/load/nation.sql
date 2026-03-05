INSERT INTO nation SELECT c1, c2, c3, c4  FROM S3 (
        "uri" = "s3://${STORAGE_BUCKET}/tpch/sf100/*",
        "format" = "csv",
        "s3.endpoint" = "${STORAGE_ENDPOINT}",
        "s3.region" = "${STORAGE_REGION}",
        "column_separator" = "|"
);