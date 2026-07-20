# BinderLab：Android Binder 实机证据工程

BinderLab 是一个可独立克隆、构建和复核的 Binder 实验工程。它用受控阻塞、requestId 和独立运行模式验证线程、oneway、callback 与死亡通知语义，不作为业务项目模板。

仓库地址：

```powershell
git clone https://github.com/HeftyL/BinderLab.git
cd .\BinderLab
```

复核本文结果时使用证据发布 tag `android16-qpr2-evidence-v1.2`；`main` 可能继续变化：

```powershell
git checkout --detach android16-qpr2-evidence-v1.2
```

实验基线：

| 项目 | 配置或实测值 |
|---|---|
| Framework / JNI / libbinder 源码参考 | Android 16 QPR2 `android-16.0.0_r4` |
| compile SDK | Android SDK Platform 36.1，revision 1 |
| targetSdk | 36 |
| minSdk | 26；只表示安装下限，未在 API 26 上运行验证 |
| SDK 目录 | 默认 `D:\Android` |
| Build Tools / AIDL | 36.0.0 / 36.0.0 |
| JDK | 21；证据采集环境为 21.0.3，源码/目标级别 8 |
| 实机证据 | Android 16 / API 36 |

主结论先看[关键证据](<evidence/key-evidence.md>)；完整日志、APK metadata、设备与工具链信息见[真机证据包](<evidence/README.md>)。

## 一、接口与实验

完整协议以 [`aidl/com/example/binderdemo`](<aidl/com/example/binderdemo>) 下的 AIDL 文件为准：

| 接口 | 实验职责 |
|---|---|
| `ICalculator.add()` | 最小同步调用，不承载故障注入 |
| `ICalculator.addWithRequestId(requestId, a, b, injectHandlerBlocker)` | 同步 Binder 入口等待 Handler；布尔参数只切换实验 blocker，按 requestId 切分延迟里程碑 |
| `ICalculator.notifyValue()` | 同一个 `ICalculator.Stub` / node 的 oneway 串行 |
| `ICalculator.getAsyncWorker()` | 返回两个独立 `IAsyncWorker.Stub`，构造不同 node 并发对照 |
| `ICalculator.notifyValueViaHandler()` | Binder 入口、Handler 与异步 callback 三阶段 |
| `ICalculator.addAndCallback()` | 同步嵌套 callback 与等待线程复用 |
| `IResultCallback` | oneway 异步反向事务 |
| `ISyncResultCallback` | 非 oneway 同步反向事务 |

六个 requestId mode 的事务和日志都带 `requestId`；`binder-death` 使用 connectionEpoch / generationId，并在杀进程前后用 requestId 关联最后成功与旧 Proxy 探测。基础教学方法 `add()` 和连接建立方法不属于这些实验。相同数值但 requestId 或 generation 不同，不能拼成同一条调用链。

## 二、实验隔离与运行模式

启动图标只建立连接，不自动运行实验。每次只选择一个 mode，并单独清理日志，避免同一 node 的 oneway backlog 混入其他实验：

| mode | 只观察什么 |
|---|---|
| `handler-latency-baseline` | 不注入长 blocker 的 `C0 → S0 → H0A → H0B → H1 → H2 → S1 → C1` |
| `handler-latency-blocked` | 同一路径注入 1.5 s 队头 blocker，和 baseline 做差异对照 |
| `sync-reentry` | 同一 requestId 的同步嵌套顺序和 TID 复用 |
| `oneway-same-node` | 同一 `ICalculator` node 上三笔 oneway 的区间关系 |
| `oneway-cross-node` | N1 两笔与 N2 两笔的不同 node 对照 |
| `async-callback` | oneway 返回、服务端入口、Handler、反向 callback 的先后关系 |
| `binder-death` | ACTIVE 旧代失效、旧代理 DeadObjectException 与显式测试重绑的新代 |

`oneway-same-node` 与 `oneway-cross-node` 是一组证据，不能只跑前者就把“不重叠”唯一归因于 node 级串行。

## 三、构建

工程故意不依赖 Gradle，直接展开 AIDL 生成、Java 编译、D8、打包和签名。这个 raw build 用于展示并固定底层构建步骤，不替代 Android Gradle Plugin、manifest merger、Android Lint 或完整 minSdk API 合规检查。默认环境可直接执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

如果 SDK 不在 `D:\Android`，显式覆盖，避免脚本静默选错平台：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 `
  -SdkRoot 'E:\AndroidSdk' `
  -CompileSdkPlatform '36.1' `
  -BuildToolsVersion '36.0.0'
```

产物为：

```text
build/BinderLab-debug.apk
```

首次构建会在被 Git 忽略的 `.debug/debug.keystore` 生成本地实验签名，后续构建复用它，保证 `adb install -r` 可升级安装。删除 `.debug/` 会改变签名；设备已有旧签名 APK 时必须先卸载，不能把签名不匹配误判为 Android 16 安装兼容问题。

可用下面两条命令核对 APK：

```powershell
D:\Android\build-tools\36.0.0\aapt2.exe dump badging .\build\BinderLab-debug.apk
D:\Android\platform-tools\adb.exe shell dumpsys package com.example.binderdemo
```

`build/toolchain.txt` 必须记录 `sdkPlatform=android-36.1`；AAPT2 badging 则确认 `compileSdkVersion=36`、`targetSdkVersion=36`、`minSdk=26`。前者证明实际加载的 36.1 平台，后者记录 APK 的整数 SDK 元数据。

## 四、安装与单项采集

不要把 `am start -W` 后紧跟 `logcat -d` 当成完整采集：`-W` 只等待 Activity 启动，oneway 服务端工作和异步 callback 可能仍未结束。使用按完成 marker 轮询的脚本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\run-experiment.ps1 `
  -Mode sync-reentry
```

如果同时连接多台设备，必须显式选择目标，避免日志、kill 和 APK 落到不同手机：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\run-experiment.ps1 `
  -Mode handler-latency-baseline `
  -DeviceSerial '<deviceSerial>'
```

脚本会安装 APK、`force-stop`、清日志、启动单一 mode，再等待：

| mode | 完成条件 |
|---|---|
| `handler-latency-baseline` | 同 requestId 且 `injectHandlerBlocker=false` 的 `C1` |
| `handler-latency-blocked` | 同 requestId 且 `injectHandlerBlocker=true` 的 `C1` |
| `sync-reentry` | `C_SYNC_CALL_END` |
| `oneway-same-node` | 三个指定 requestId 的 `S_ONEWAY_EXIT` |
| `oneway-cross-node` | 四个指定 requestId 的 `S_ASYNC_WORKER_EXIT` |
| `async-callback` | `C_ASYNC_CALLBACK_OBSERVED` |
| `binder-death` | 旧代失效、旧代理 DeadObjectException、新代 ACTIVE，且新代出现 `C_EXPERIMENT_NOT_RESTARTED` |

默认日志写入被 Git 忽略的 `build/run-logs/`。重新生成公开证据包时，从 clean commit 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\collect-evidence.ps1
```

采集脚本会重新构建 APK、逐项运行实验、去除设备标识，并记录源码 commit、源码清单、工具链、设备信息、原始日志与结构化分析。文件用途和可复核边界见 [`evidence/README.md`](<evidence/README.md>)。

## 五、每组实验怎样判定

### 1. Handler 延迟

两组使用同一个 AIDL 方法、Handler 和分析器，只改变 `injectHandlerBlocker`。每轮都记录八个单调时刻：

```text
C0：客户端同步调用开始
S0：服务端 Binder 入口开始
H0A：调用 Handler.post() 前
H0B：post() 已返回，并记录 true / false
H1：Runnable 开始执行
H2：Runnable 离开执行区间
S1：服务端 Binder 入口结束
C1：客户端同步调用返回或失败
```

只在 `postAccepted=true` 的正常路径计算七个互不重叠片段：

```text
S0 - C0
H0A - S0
post 调用开销上界 = H0B - H0A
可观测队列等待   = H1 - H0B
H2 - H1
S1 - H2
C1 - S1
```

分析器不直接相信日志中的 `postCallNs`、`queueNs`、`runNs`、`serverNs` 或 `costNs` 自报值，而是从八个 `atNs` 重新计算。七个相邻片段之和按首尾相消定义等于 C1-C0，这项只检查时间点单调和分片算术是否写对；独立性更强的检查是把上述 duration 字段逐一与相应 `atNs` 差值交叉核对。它不能证明日志已经覆盖服务内部所有真实阶段。

两组都使用短 `postReturned` 测量闩锁，让 Runnable 等到调用线程写完 H0B 后才记录 H1；只有 blocked 组额外放入 1.5 s blocker。这个闩锁建立可计算边界，也会带来少量调度/握手开销，所以 H1-H0B 仍是工程可观测等待，不是 `MessageQueue` 内部纯排队值。一般代码若没有等价握手，Looper 可能在调用线程刚从 `post()` 返回、尚未记录 H0B 时就开始任务；不能把负值或极小值硬解释成精确排队时间。

### 2. 同步重入

同步重入需要同时满足：

```text
C_SYNC_CALL_BEGIN(requestId=X, tid=A, atNs=t0)
  S_BEFORE_SYNC_CALLBACK(requestId=X, atNs=t1)
    C_SYNC_CALLBACK(requestId=X, tid=A, atNs=t2, insideOuterCall=true)
  S_AFTER_SYNC_CALLBACK(requestId=X, atNs=t3)
C_SYNC_CALL_END(requestId=X, tid=A, atNs=t4)
```

只有“相同 requestId + marker 顺序严格嵌套 + `t0 < t1 < t2 < t3 < t4` + callback TID 等于外层等待 TID”联合成立，才能说本次运行复用了原等待线程。五个 `atNs` 都来自同一台设备的 `elapsedRealtimeNanos()` 单调时基，可以跨本实验的 App / `:remote` 进程比较；分析器从原始 marker 独立比较 requestId、顺序、时间和 TID。App 自报的 `insideOuterCall` / `reusedWaitingThread` 只作辅助字段，只看到两个 TID 相等不够。

### 3. 同 node 与不同 node 的 oneway

`oneway-same-node` 的三笔事务都发给同一个 `ICalculator.Stub`。区间不重叠与同 node 串行语义一致，但单独看它无法排除“当时只有一条活跃 Binder 线程”。

`oneway-cross-node` 先同步取得 N1、N2 两个独立 `IAsyncWorker.Stub`，再由两条客户端线程同时发送：

```text
线程 A：N1.work(requestId=1) → N1.work(requestId=2)
线程 B：N2.work(requestId=3) → N2.work(requestId=4)
```

两边各发两笔是为了形成可核验 backlog，不是为了制造“必然重叠”。强证据需要同时满足：

```text
C_N1_CALL_RETURN(第二笔) < S_N1_EXIT(第一笔)
C_N2_CALL_RETURN(第二笔) < S_N2_EXIT(第一笔)
每个 node 自己的服务端区间不重叠
N1 与 N2 至少一组区间重叠，且服务端 TID 不同
```

前两条排除“第二笔直到第一笔结束后才由客户端发送”的替代解释；后两条把同 node 串行和进程具备多条活跃 Binder 线程放进同一对照。不同 node 只代表 Binder 允许并发；若某次没有重叠，可能是调度或线程池状态，不等于 Binder 保证每次并行。

### 4. Handler 与异步 callback

分析器只把下列稳定偏序作为通过门禁：

```text
C_ASYNC_CALL_BEGIN < C_ASYNC_CALL_RETURN
C_ASYNC_CALL_BEGIN < S_HANDLER_POST < S_HANDLER_RUN < C_CALLBACK < C_ASYNC_CALLBACK_OBSERVED
C_ASYNC_CALL_RETURN < C_ASYNC_CALLBACK_OBSERVED
```

`C_ASYNC_CALL_RETURN` 只表示调用方没有等待服务端业务完成。它与 `S_HANDLER_POST`、`S_HANDLER_RUN`、`C_CALLBACK` 的跨进程先后受并发调度影响，不是平台保证；因此六个 marker 的总顺序只作为描述字段，不参与通过判定。合成回归会接受 post 或 callback 早于 return 的合法交错，并分别拒绝破坏上述每条稳定边的调度。无论日志怎样交错，这都不是同步嵌套，也不能证明等待线程复用。

## 六、API 36 实机结果

实验在 Android 16 / API 36 手机上逐项清日志运行。跨进程排序使用设备的 `elapsedRealtimeNanos()`；采集时间和时钟信息见 [`device.txt`](<evidence/device.txt>) 与 [`source.txt`](<evidence/source.txt>)。

| mode | 实际观测 | 本次运行可以支持的结论 |
|---|---|---|
| `handler-latency-baseline` | [关键行](<evidence/key-evidence.md#binder-key-handler>)与[结构化分析](<evidence/analysis.json>)：固定轮数全部通过同 requestId、时间点顺序、算术分片和 duration 交叉检查 | 给 blocked 组提供同协议、同 Handler 路径的无长 blocker 基线；绝对耗时包含调度和测量握手 |
| `handler-latency-blocked` | [关键行](<evidence/key-evidence.md#binder-key-handler>)与[结构化分析](<evidence/analysis.json>)：`post()` 自身仍短，新增等待集中在 `H0B → H1`；blocked 最小队列等待与 baseline 最大值之差接近注入的长 blocker 时长，即 `blocked.queueNsMin - baseline.queueNsMax ~= injectedBlockerNs` | 新增主要延迟位于 Handler 可观测等待，而不是 `post()` 调用；绝对值不是性能基准 |
| `sync-reentry` | [关键行](<evidence/key-evidence.md#binder-key-sync-reentry>)：requestId 一致，五个 marker 顺序与 `atNs` 都严格递增；callback TID 等于外层等待 TID | 本次运行复用了原等待线程 |
| `oneway-same-node` | [`oneway-same-node.log`](<evidence/oneway-same-node.log>)：第二笔客户端调用已返回时第一笔仍在执行，三个服务端区间仍依次执行 | 形成 backlog 后的结果与同 node oneway 串行一致 |
| `oneway-cross-node` | [关键行](<evidence/key-evidence.md#binder-key-node>)与[结构化分析](<evidence/analysis.json>)：N1/N2 第二笔均提前提交；node 内串行；不同 Binder TID 上存在超过分析器门槛的显著重叠 | 排除了“第二笔发送太晚”“只有零星时间戳擦边”和“进程只有一条活跃 Binder 线程”三个替代解释 |
| `async-callback` | [`async-callback.log`](<evidence/async-callback.log>)：同 requestId 的 post、run、callback、observed 严格成立；正反向业务 Proxy 与 BinderProxy 四个 class 均直接记录 | 服务端入口、Handler 与反向 callback 已在独立 run 中分离，正反向引用角色有直接 class 证据 |
| `binder-death` | [关键行](<evidence/key-evidence.md#binder-key-death>)：generation 1 杀进程前最后一笔调用返回 42；随后 `binderDied` 失效当前代，受控旧代理探测抛 DeadObjectException，显式 rebind 发布 generation 2 且不重启实验 | 覆盖 T1、实际 T3→受控 T2 顺序、T4 与一次性 gate；不等于任意在途调用竞态或完整业务恢复 |

这些结果来自受控实验，不是性能基线。换设备、负载或调度状态后，绝对时间和 TID 都可能变化；具体数值以 `key-evidence.md` 和 `analysis.json` 为准。

## 七、generation 失效保护的准确边界

客户端 generation 显式经过：

```text
CONNECTING → LINKED → REGISTERED → ACTIVE → INVALID
```

只有完成 `linkToDeath()` 和 callback 注册的 candidate 才会发布到 `generationRef`；读取方只接受 ACTIVE。每条状态日志都带 `connectionEpoch`、`generationId`、进程内 `binderIdentity`、old/new state 和 reason。DeathRecipient 捕获具体 generation，并用对象级 CAS 清理当前代；只有 `wasCurrent=true` 才继续旧 Proxy 探测和实验重绑。迟到的旧代死亡回调会记录 `C_STALE_DEATH_IGNORED`，既不能清掉新代，也不能借后续动作扰动新代。

`linkToDeath()` 成功与 Java 状态转为 LINKED 之间存在窄窗口，因此清理不依赖 `deathLinked` 布尔值，而是无条件 best-effort `unlinkToDeath()`；“未注册、已死亡、已经解除”都作为可接受清理结果记录。相关状态转换、CAS 清理和受控旧 Proxy 探测均可由本仓代码与死亡实验日志直接复核。

`binder-death` 先完成 generation 1 的成功事务，再杀死 `:remote`；死亡回调使旧代 INVALID，受控旧代理探测得到 `DeadObjectException`，随后实验代码显式 unbind/rebind 并发布 generation 2。完整顺序见[关键证据](<evidence/key-evidence.md#binder-key-death>)。

该实验不覆盖在途业务调用与死亡通知的自然竞态，也不验证迟到旧 `DeathRecipient`、自动重试、业务 session 恢复或多绑定连接管理。

可在 debug APK 上验证死亡路径：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\run-experiment.ps1 `
  -Mode binder-death
```

## 八、实验代码边界

- `notifyValue()` 和 `IAsyncWorker.work()` 故意在 Binder 线程中 sleep，只用于把区间放大；生产 oneway 同样会占用服务端 Binder 线程和 async 队列。
- `addWithRequestId()` 故意让 Binder 线程同步等待 Handler；生产代码应先判断是否真的需要同步完成语义，并设置超时、取消和降级策略。
- APK 显式 `debuggable=true`，只为 `run-as` 死亡实验；不要把它作为发布配置。
- oneway 不等待服务端业务完成，不等于调用方零成本、绝不等待或绝不失败。Parcel 编码、进入驱动、buffer 压力与本地同进程退化路径仍在调用方路径上。
- callback 参数在服务端显式判空，`RemoteCallbackList.register()` 的失败也会被处理，避免把输入问题误判成 Binder 机制故障。

真实 RCA 仍要把 Binder flow、线程栈、里程碑日志和服务状态交叉验证；单次总耗时、单张栈或 Java class 都不能替代完整因果链。

## 九、自动校验

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
```

校验器会以 SDK Platform 36.1、Build Tools / AIDL 36.0.0 重新构建，并检查 AIDL 协议、生成物哈希、APK SDK 元数据与签名、证据日志重算、关键证据页、来源清单、隐私字段、Markdown 链接和 Git whitespace。CI 使用同一校验入口；真机证据仍需在连接设备的环境中采集。
