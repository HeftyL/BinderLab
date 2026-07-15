# Build Tools 36.0.0 生成主干摘录

本页从 `build/generated/com/example/binderdemo/ICalculator.java` 摘出用于理解协议的 Stub / Proxy 主干。省略默认实现、回收模板和重复方法；完整生成文件由 AIDL、固定工具链与 [`aidl-generated.sha256`](<aidl-generated.sha256>) 共同复现。

## Stub：按 transaction code 读参数并调用本地实现

```java
case TRANSACTION_addWithRequestId: {
    int _arg0 = data.readInt();
    int _arg1 = data.readInt();
    int _arg2 = data.readInt();
    boolean _arg3 = (0 != data.readInt());
    int _result = this.addWithRequestId(_arg0, _arg1, _arg2, _arg3);
    reply.writeNoException();
    reply.writeInt(_result);
    break;
}
```

Build Tools 36.0.0 的本次 Java 输出没有生成 `enforceNoDataAvail()`；正文不能把其他 AIDL 编译器版本的分支写成本次逐行结果。

## Proxy：同步调用需要 reply

```java
_data.writeInterfaceToken(DESCRIPTOR);
_data.writeInt(requestId);
_data.writeInt(a);
_data.writeInt(b);
_data.writeInt(injectHandlerBlocker ? 1 : 0);
mRemote.transact(Stub.TRANSACTION_addWithRequestId, _data, _reply, 0);
_reply.readException();
_result = _reply.readInt();
```

## Proxy：oneway 使用 null reply 与 FLAG_ONEWAY

```java
_data.writeInterfaceToken(DESCRIPTOR);
_data.writeInt(requestId);
_data.writeInt(value);
mRemote.transact(
        Stub.TRANSACTION_notifyValue,
        _data,
        null,
        android.os.IBinder.FLAG_ONEWAY);
```

## callback 与返回 Binder 引用

```java
_data.writeStrongInterface(callback);

_result = com.example.binderdemo.IAsyncWorker.Stub.asInterface(
        _reply.readStrongBinder());
```

前一行把 callback Binder 引用写入 Parcel；后一段把服务端返回的 Binder 引用重新包装成 `IAsyncWorker`。它们都不是普通整数参数。

## 当前 transaction constants

```java
TRANSACTION_add                   = IBinder.FIRST_CALL_TRANSACTION + 0;
TRANSACTION_notifyValue           = IBinder.FIRST_CALL_TRANSACTION + 1;
TRANSACTION_notifyValueViaHandler = IBinder.FIRST_CALL_TRANSACTION + 2;
TRANSACTION_registerCallback      = IBinder.FIRST_CALL_TRANSACTION + 3;
TRANSACTION_addAndCallback        = IBinder.FIRST_CALL_TRANSACTION + 4;
TRANSACTION_getAsyncWorker        = IBinder.FIRST_CALL_TRANSACTION + 5;
TRANSACTION_addWithRequestId      = IBinder.FIRST_CALL_TRANSACTION + 6;
```
