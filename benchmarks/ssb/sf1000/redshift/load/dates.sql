copy dates
from
    's3://${STORAGE_BUCKET}/ssb/sf1000/date/' iam_role default GZIP DELIMITER '|'  REGION 'us-east-1';