copy customer_address
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/customer_address/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';