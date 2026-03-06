copy warehouse
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/warehouse/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';