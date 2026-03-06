-- Load Amazon Reviews from S3 Parquet dataset
-- Source: https://${STORAGE_BUCKET}.s3.${STORAGE_REGION}.amazonaws.com/amazon_review/
-- Total: 135,589,433 reviews (2010-2015)

INSERT INTO amazon_reviews
SELECT * FROM S3 (
    "uri" = "https://${STORAGE_BUCKET}.s3.${STORAGE_REGION}.amazonaws.com/amazon_review/amazon_reviews_{2010,2011,2012,2013,2014,2015}.snappy.parquet",
    "format" = "parquet",
    "s3.access_key" = "*XXX",
    "s3.secret_key" = "*XXX"
);
