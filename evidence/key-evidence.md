# BinderLab 关键证据

本页由 `analyze-evidence.ps1` 从原始日志生成，只保留支撑正文主结论的必要 marker。完整 `threadtime` 日志用于审计，结构化判定见 [`analysis.json`](<analysis.json>)。PID、TID、requestId 和耗时只属于本次运行。

<a id="binder-key-handler"></a>

## 1. Handler baseline 与 blocked 对照

baseline（run-01）：

```text
H0B requestId=1001 injectHandlerBlocker=false postCallNs=828307
H1  requestId=1001 queueNs=4724308
C1  requestId=1001 costNs=14343384
```

blocked（run-01）：

```text
H0B requestId=1001 injectHandlerBlocker=true postCallNs=300077
H1  requestId=1001 queueNs=1501207308
C1  requestId=1001 costNs=1507291154
```

两组 `post()` 自身都很短；本轮 blocked 新增的约 1.5 秒主要落在 `H0B → H1`。五轮区间和阈值检查见[证据说明](<README.md#binder-evidence-results>)。

<a id="binder-key-sync-reentry"></a>

## 2. 同步嵌套与等待线程复用

```text
C_SYNC_CALL_BEGIN      requestId=1001 tid=5636 atNs=t0+0ns
S_BEFORE_SYNC_CALLBACK requestId=1001 atNs=t0+2583385ns
C_SYNC_CALLBACK        requestId=1001 tid=5636 waitingTid=5636 atNs=t0+4474154ns
S_AFTER_SYNC_CALLBACK  requestId=1001 atNs=t0+6232231ns
C_SYNC_CALL_END        requestId=1001 tid=5636 atNs=t0+7597769ns
```

这里以 `C_SYNC_CALL_BEGIN.atNs` 为 `t0`；原始绝对值保留在完整日志和 `analysis.json`。相同 requestId、marker 与 `atNs` 双重严格嵌套顺序，以及 `callback TID = 外层等待 TID` 联合成立，因此只能表述为：**本次运行复用了原等待线程**。

<a id="binder-key-node"></a>

## 3. 不同 node 并发、同 node 内串行

以下按“要证明的关系”分组，不表示完整日志顺序；并发 marker 在文本中的显示先后不参与结论。

```text
本节 `t0` 取下面展示时间点中的最早值；原始绝对值仍保留在完整日志和 `analysis.json`。

提前提交：
C_N1_CALL_RETURN(requestId=1002).atNs=t0+868693ns
  < S_ASYNC_WORKER_EXIT(node=N1, requestId=1001).end=t0+701142847ns
C_N2_CALL_RETURN(requestId=1004).atNs=t0+3943385ns
  < S_ASYNC_WORKER_EXIT(node=N2, requestId=1003).end=t0+706861231ns

跨 node 重叠：
N1[1001] = [t0+0ns, t0+701142847ns), tid=5763
N2[1003] = [t0+5413539ns, t0+706861231ns), tid=5760
overlap(N1[1001], N2[1003]) = 695729308 ns

各 node 内串行：
N1[1001].end=t0+701142847ns
  <= N1[1002].begin=t0+703441539ns
N2[1003].end=t0+706861231ns
  <= N2[1004].begin=t0+707704308ns
```

两条第二笔调用均在各自第一笔退出前完成提交；N1/N2 的第一笔在不同 Binder TID 上形成显著正重叠，而每个 node 的第二笔都在第一笔退出后才进入。

<a id="binder-key-death"></a>

## 4. 死亡通知与 generation 切换

```text
C_LAST_SUCCESS_END requestId=1001 result=42
C_GENERATION_INVALID connectionEpoch=1 generationId=1 oldState=ACTIVE wasCurrent=true reason=binderDied
C_OLD_PROXY_DEAD_OBJECT generationId=1 exception=DeadObjectException
C_GENERATION_STATE connectionEpoch=2 generationId=2 newState=ACTIVE
C_EXPERIMENT_NOT_RESTARTED generationId=2
```

本轮准确顺序是：`T1 最后成功 → T3 binderDied → 受控 T2 旧代理探测失败 → T4 显式 rebind 发布 generation 2`。这是实验代码主动安排的观测顺序，**不是平台保证 T3 永远早于自然发生的 T2**。分析器还要求 ACTIVE 恰好两次、generationId/connectionEpoch 都是 `1 → 2`，且新代恰好一次记录 `C_EXPERIMENT_NOT_RESTARTED`。
