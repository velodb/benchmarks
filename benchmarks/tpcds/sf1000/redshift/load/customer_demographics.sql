copy customer_demographics
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/customer_demographics/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';