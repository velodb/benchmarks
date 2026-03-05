INSERT INTO customer (
    c_custkey,c_name,c_address,c_city,c_nation,c_region,c_phone,c_mktsegment
)SELECT * FROM S3 (
        "uri" = "s3://${STORAGE_BUCKET}/ssb/sf100/*",
        "format" = "csv",
        "s3.endpoint" = "${STORAGE_ENDPOINT}",
        "s3.region" = "${STORAGE_REGION}",
        "column_separator" = "|",
        csv_schema = "c_custkey:int;c_name:string;c_address:string;c_city:string;c_nation:string;c_region:string;c_phone:string;c_mktsegment:string",
        "compress_type"="gz"
);