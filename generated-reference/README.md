# AIDL 生成物审计参考

这里不提交完整 `build/generated/`，也不把生成文件冒充手写源码。当前目录固定三件事：

- [`toolchain.txt`](<toolchain.txt>)：生成环境和参数；
- [`aidl-generated.sha256`](<aidl-generated.sha256>)：四个 Java 生成文件的完整 SHA-256；
- [`ICalculator-mainline-snippet.md`](<ICalculator-mainline-snippet.md>)：用于复核 transaction code、Parcel 和 Binder 引用传递的 Stub / Proxy 主干。

执行 `..\verify.ps1` 会用 Build Tools 36.0.0 重新生成四个接口，比较哈希、transaction code、oneway flags、callback Binder 参数和返回 Binder 引用。任何 AIDL 或工具链变化都必须同时重新审阅生成结果、片段和哈希，不能只把校验值机械更新成绿色。

生成文件使用 `--omit_invocation`，避免把作者机器绝对路径写入哈希。`aidl-generated.sha256` 证明“本次生成结果是什么”；它不证明其他 Build Tools 版本会逐字生成相同文件。
