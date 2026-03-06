copy catalog_page
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/catalog_page/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';