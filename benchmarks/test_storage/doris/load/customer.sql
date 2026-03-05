INSERT INTO customer SELECT * FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/test_storage/customer.tbl",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}"
);
