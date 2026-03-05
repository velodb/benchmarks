INSERT INTO customer_demographics (cd_demo_sk, cd_gender, cd_marital_status, cd_education_status, cd_purchase_estimate, cd_credit_rating, cd_dep_count, cd_dep_employed_count, cd_dep_college_count) SELECT * FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/tpcds/sf100/customer_demographics/*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|"
);
