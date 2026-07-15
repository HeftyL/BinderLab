# BinderLab Android 16 / API 36 真机证据包

本目录保存在 Android 16 / API 36 真机上由 [`collect-evidence.ps1`](<../collect-evidence.ps1>) 自动采集并在全部检查通过后发布的公开证据。准确的 host/device 时间、时区标识和 captureId 见 [`device.txt`](<device.txt>)、[`source.txt`](<source.txt>)；UTC 偏移本身不被当成唯一 IANA 时区。它用于让仓库中的实机结论可以被读者逐行复核，不是性能基准，也不是该手机 Framework / kernel 与本仓源码参考基线完全同版的证明。

## 一、环境和隐私边界

| 维度 | 本次证据 |
|---|---|
| 编译 SDK | Android SDK Platform 36.1，revision 1 |
| `targetSdk` / `minSdk` | 36 / 26 |
| Build Tools / AIDL 包 | 36.0.0 / 36.0.0 |
| 设备 | Android 16 / API 36 |
| 设备 kernel | 公开材料只保留 major.minor：6.6 |
| JDK / adb | 21.0.3 / Platform-Tools 35.0.2 |

`toolchain.txt` 的 `sdkPlatform=android-36.1` 证明编译输入；`apk-badging.txt` 的 `compileSdkVersion=36` 是 AAPT2 对 minor SDK 的整数表示。`minSdk 26` 只声明安装下限，本证据只支持 Android 16 / API 36 实机结论。

公开材料把机型、carrier、完整 build fingerprint、完整 kernel release 和设备序列号全部移除；`device.txt` 只保留 Android/API、build type、kernel major.minor 和必要的时间轴元数据。隐私校验只检查通用字段/格式，不在脚本中反向保存被删掉的具体标识作为黑名单。PID、TID、generationId 和 `binderIdentity` 只在本次日志进程生命周期内有意义，不能用于跨设备识别。

## 二、文件怎样对应结论

| 文件 | 用途 |
|---|---|
| [`device.txt`](<device.txt>) | 已去标识的系统/API、build type、kernel major.minor、host/device 时间与时区信息 |
| [`toolchain.txt`](<toolchain.txt>) | Platform、Build Tools、AIDL、AAPT2、D8、JDK、adb 的实际版本 |
| [`service-manager.txt`](<service-manager.txt>) | `activity` 的 service check、名称/descriptor 和服务宿主 PID 窄范围输出 |
| [`apk-badging.txt`](<apk-badging.txt>) | APK SHA-256 和 AAPT2 元数据 |
| [`apk-signature.txt`](<apk-signature.txt>) | `apksigner verify --verbose --print-certs` 原始输出 |
| [`commands.txt`](<commands.txt>) | 完整构建、安装、启动、等待和分析命令 |
| `*.log` | `adb logcat -d -v threadtime -s BinderLab:I '*:S'` 的 tag 级原始输出，未重排事件 |
| [`key-evidence.md`](<key-evidence.md>) | 分析器从原始日志自动生成的四组关键 marker；不是手工摘录 |
| [`analysis.json`](<analysis.json>) | 自带 captureId / 开始时间，由 [`analyze-evidence.ps1`](<../analyze-evidence.ps1>) 从原始日志复算的结构化结论 |
| [`source.txt`](<source.txt>) | captureId、基线 Git commit/branch、采集开始时 dirty 状态、APK 与源码清单哈希 |
| [`source-manifest.sha256`](<source-manifest.sha256>) | 以仓库相对路径记录仓库根 `.gitattributes`，以及产生实验 APK/日志所依赖的 manifest、AIDL、Java 与脚本逐文件 SHA-256 |
| [`evidence-manifest.sha256`](<evidence-manifest.sha256>) | 证据目录中除清单自身外每个文件的 SHA-256；文件集合、文件名与内容必须同时匹配 |

日志是 BinderLab tag 的原始 `threadtime` 输出，不是整机全量 logcat。每一轮都先 `force-stop`、清 logcat，再启动一个 mode；采集脚本等待服务端完成 marker，而不是依赖固定 `Start-Sleep`。公开采集只接受 clean working tree，固定重新构建 APK，并在构建前冻结源码清单；分析后和正式发布前再次逐项比较，同时确认 Git HEAD 未变化，任一输入漂移都会拒绝发布。所有输出先写入 capture 专属 staging，只有文件集合完整、分析和上述来源检查全部通过后，才用 backup + rollback 的事务式目录发布替换正式目录。启动时发现残留 staging/backup 会中止并提示人工恢复；该设计避免普通异常造成新旧日志混合，但不宣称机器断电时仍是严格 crash-atomic replacement。

`apkSha256` 只绑定“本次真机运行使用的 APK”。debug keystore 在每台机器本地生成，ZIP 时间等输入也可能变化，因此它不承诺读者重建后得到逐字节相同的 APK；源码一致性由 `source-manifest.sha256` 独立约束。两个 SHA-256 清单都是可复算的一致性索引，不是外部签名，也不提供不可伪造性；可信起点仍是公开 Git commit、仓库历史和远端 CI 记录。

本次 [`source.txt`](<source.txt>) 必须记录 `gitDirty=false`。`verify.ps1` 不只复算当前源码清单，还会把这些输入与 `gitCommit` 指向的 clean commit 比较；因此读者可以直接 checkout 该提交取得产生 APK 和日志的实验源码。`source-manifest.sha256` 与 APK SHA-256 继续保留，用于检测后续源码漂移和绑定本次设备实际安装的 APK。

本轮有意在“提交 A”的 detached HEAD 上采集，所以 `gitBranch=detached` 是可复现流程的结果，不代表来源不明：采集期间没有可移动的分支指针，身份由完整 `gitCommit`、`gitDirty=false` 和逐文件源码清单共同绑定。采集身份还要求 `source.txt`、`device.txt`、`analysis.json` 三者的 captureId 与开始时间分别相等，并严格满足 `captureStartedAt < analysis.generatedAt < captureCompletedAt`；这样来源、设备 metadata、分析结果和同一轮目录发布才形成直接的可机检绑定。

<a id="binder-evidence-results"></a>

## 三、本次可以复核的结果

主阅读路径先看[四组关键 marker](<key-evidence.md>)；需要逐行复核时，再进入下列完整日志和 `analysis.json`。

- Handler baseline 固定为 5 轮，文件必须恰好是 [`run-01`](<handler-latency-baseline-run-01.log>)、[`run-02`](<handler-latency-baseline-run-02.log>)、[`run-03`](<handler-latency-baseline-run-03.log>)、[`run-04`](<handler-latency-baseline-run-04.log>)、[`run-05`](<handler-latency-baseline-run-05.log>)；每轮 `post()` 自身与 `H0B → H1` 的具体值由 [`analysis.json`](<analysis.json>) 给出。
- Handler blocked 同样固定为 5 轮，文件必须恰好是 [`run-01`](<handler-latency-blocked-run-01.log>)、[`run-02`](<handler-latency-blocked-run-02.log>)、[`run-03`](<handler-latency-blocked-run-03.log>)、[`run-04`](<handler-latency-blocked-run-04.log>)、[`run-05`](<handler-latency-blocked-run-05.log>)；本次稳定结论是 `post()` 自身仍短，新增等待集中在 `H0B → H1`，且 `blocked.queueNsMin - baseline.queueNsMax ~= injectedBlockerNs`。当前捕获数值只在 [`key-evidence.md`](<key-evidence.md#binder-key-handler>) 和 [`analysis.json`](<analysis.json>) 维护。
- 上述 10 轮每轮都满足同 requestId、正确 blocker 开关和 `C0 → S0 → H0A → H0B → H1 → H2 → S1 → C1` 严格顺序。分析器从八个 `atNs` 复算七个相邻片段；片段之和按首尾相消定义等于 C1-C0，只作为算术一致性检查。更有价值的交叉检查是 `costNs/serverNs/postCallNs/queueNs/runNs` 与对应时间点差值一致；同时硬性核对客户端/服务端 PID 分离、服务端入口 TID 稳定、Handler TID 稳定且两者不同。详见 [`analysis.json`](<analysis.json>)。
- 同步重入的五个事件 requestId 相同，marker 顺序与五个 `elapsedRealtimeNanos()` 时间点都严格递增；分析器独立比较 `callerTid == callbackTid == waitingTid`，并要求 App 三个 marker 同 PID/TID、服务端两个 marker 同远端 PID/TID。App 自报布尔值仅作辅助，见 [`sync-reentry.log`](<sync-reentry.log>)。
- 同 node 三笔 oneway 的客户端第二笔在服务端第一笔退出前已经返回，但三个服务端区间仍不重叠；每个 ENTER/EXIT 还必须匹配 node、PID、TID，区间为正且 `runNs=end-begin`，服务端 requestId 顺序与客户端提交顺序一致，见 [`oneway-same-node.log`](<oneway-same-node.log>)。
- N1、N2 各自第二笔都在本 node 第一笔退出前完成客户端提交；每个 node 内仍串行且顺序等于本 node 的客户端提交顺序，不同 node 在两条不同 Binder TID 上存在超过门槛的显著重叠。所有区间继续执行 ENTER/EXIT 完整性检查，避免把错配 marker 或零星边界擦过当作并发。具体区间与重叠值见 [`key-evidence.md`](<key-evidence.md#binder-key-node>)、[`analysis.json`](<analysis.json>) 和 [`oneway-cross-node.log`](<oneway-cross-node.log>)。
- 异步链的 requestId 由原始 marker 独立比对，服务端 `POST → RUN → callback → observed` 严格成立；分析器同时要求服务端入口与 Handler 同进程不同 TID、callback 回到 App 进程且 TID 不同于实验线程。日志直接记录 `ICalculator$Stub$Proxy` / `BinderProxy` 与 `IResultCallback$Stub$Proxy` / `BinderProxy` 四个 class。本次还观察到客户端先返回，但该跨进程先后不是平台保证，见 [`async-callback.log`](<async-callback.log>)。
- 死亡实验先完成 generation 1 的最后成功事务（requestId 1001，结果 42），再由主机 kill。随后 `binderDied` 以 `wasCurrent=true` 失效当前代，测试代码才对旧代理做 requestId 1002 的受控探测并得到 `DeadObjectException`，所以本次明确顺序是 `binderDied-before-controlled-dead-object-probe`。仅限实验模式的显式 rebind 以 connectionEpoch 2 发布 generation 2；分析器要求 ACTIVE 恰好两次、epoch/generation 都为 `1 → 2`、新代一次且仅一次记录未重启实验，并禁止旧代理的其他失败分支、跳过 rebind 和 stale callback marker，见 [`binder-death.log`](<binder-death.log>)。

以上硬条件由 `analysis.json` 的 `allRequiredChecksPassed=true` 汇总。`threadNameConsistentWithBinderPool`、`handlerThreadNameMatchesConfiguredWorker` 等线程名字段仍保留为辅助观察，但不进入总门禁：线程名是实现标签，硬拓扑只依赖 PID/TID 和事件关系。修改解析器时必须回看原始日志，不能用“脚本变绿”代替证据语义审查。

<a id="binder-evidence-limits"></a>

## 四、不能从这份证据推出什么

- 不能推出手机使用 `android-16.0.0_r4` Framework 或 Android Common 6.12 参考源码；公开设备事实只确认 kernel 6.6 系列。
- 不能从 Java 日志证明驱动内部每个 `binder_transaction`、work queue 或调度决策；真实 Binder flow 仍需单独采集并解析 Perfetto 证据。
- 不能把同 APK 的 App / `:remote` 两进程用于 UID 数值变化实验；它们默认共享 Linux UID。identity 真机实验需要双 UID APK 或经过审计的 isolated-process 设计。
- `binder-death` 的第二代来自实验代码的明确 rebind。`BIND_AUTO_CREATE` 提供组件创建语义，但不能被写成应用已经拥有重试、退避、业务恢复和幂等重放。
- 本轮的旧 Proxy `DeadObjectException` 是 `binderDied` 回调后由测试代码主动触发的受控探测，不覆盖任意在途业务调用与死亡通知的自然竞态顺序。
- generation 代码具备 stale-death guard，但本轮没有人为制造“旧 DeathRecipient 延迟到新代发布后才回调”；不得把未出现的 `C_STALE_DEATH_IGNORED` 当作已实测结果。
