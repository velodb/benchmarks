INSERT INTO region SELECT c1, c2, c3 FROM S3 (
        "uri" = "s3://${STORAGE_BUCKET}/tpch/sf100/region/*",
        "format" = "csv",
        "s3.endpoint" = "${STORAGE_ENDPOINT}",
        "s3.region" = "${STORAGE_REGION}",
        "column_separator" = "|"
);