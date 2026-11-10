# PostgreSQL 实验区（待建）

和 mysql/ 同样的玩法：docker compose 起一主一从（流复制 + Patroni），然后注入故障。
待补的实验：复制槽堆积、XID 回卷、表膨胀、checkpoint 风暴、长事务撑爆磁盘。
先在 mysql/ 做熟两个再动这里。
