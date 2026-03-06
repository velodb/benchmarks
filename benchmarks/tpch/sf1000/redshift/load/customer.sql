copy customer
from
    's3://${STORAGE_BUCKET}/tpch/sf1000/customer/' iam_role default GZIP DELIMITER '|' REGION 'us-east-1';
