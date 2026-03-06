copy store_returns
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/store_returns/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';