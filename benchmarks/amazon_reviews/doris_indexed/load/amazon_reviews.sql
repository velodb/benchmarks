-- Load Amazon Reviews from S3 Parquet dataset
-- Source: https://bench-dataset.s3.us-east-1.amazonaws.com/amazon_review/
-- Total: 135,589,433 reviews (2010-2015)

INSERT INTO amazon_reviews
SELECT * FROM S3 (
    "uri" = "https://bench-dataset.s3.us-east-1.amazonaws.com/amazon_review/amazon_reviews_{2010,2011,2012,2013,2014,2015}.snappy.parquet",
    "format" = "parquet",
);
