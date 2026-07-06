INSERT INTO reason (r_reason_sk, r_reason_id, r_reason_desc) SELECT r_reason_sk, r_reason_id, r_reason_desc FROM tpcds.sf100.reason;
