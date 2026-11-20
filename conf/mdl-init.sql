-- 02 号实验的初始化数据。
--
-- 只要有「一张有数据的表」就能演 MDL：有人开事务读它不提交，
-- 别人的 ALTER 就得排队。10 万行是为了让 ALTER 有东西可做，
-- 顺便让「后面排队的 SELECT」有时长可看。
--
-- 表结构跟 01 的 t_pk 保持一致，docs/02 里的查询换实验也能直接用。

CREATE DATABASE IF NOT EXISTS demo;
USE demo;

CREATE TABLE IF NOT EXISTS t_pk (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uid BIGINT UNSIGNED NOT NULL,
  amount DECIMAL(12,2) NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_uid (uid)
) ENGINE=InnoDB;

SET SESSION cte_max_recursion_depth = 200000;

INSERT INTO t_pk (uid, amount)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 100000)
SELECT n % 5000, ROUND(RAND()*1000, 2) FROM seq;
