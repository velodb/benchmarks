copy store_sales
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/store_sales/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';