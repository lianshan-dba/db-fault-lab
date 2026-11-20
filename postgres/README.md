# PostgreSQL 实验区（待建）

跟 `labs/` 下的 MySQL 实验同一套约定：**一个实验一个目录，自带 compose + 注入 + 复原**，
`lab.sh` 不认具体实验，只读目录里的 `meta`。等动工时目录长这样：

```
labs/08-pg-repl-slot/     meta  compose.yml  conf/  inject.sh  reset.sh
```

待补的实验：复制槽堆积、XID 回卷、表膨胀、checkpoint 风暴、长事务撑爆磁盘。
先把 MySQL 的 03 / 04 / 06 / 07 做完再动这里。
