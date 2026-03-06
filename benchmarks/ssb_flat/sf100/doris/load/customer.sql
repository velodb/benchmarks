INSERT INTO customer (c_custkey,c_name,c_address,c_city,c_nation,c_region,c_phone,c_mktsegment) SELECT c1, c2, c3, c4, c5, c6, c7, c8 FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/ssb/sf100/customer.tbl",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|",
    "skip_lines" = "0"
);