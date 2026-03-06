copy promotion
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/promotion/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';