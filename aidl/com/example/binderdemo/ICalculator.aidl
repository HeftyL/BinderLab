package com.example.binderdemo;

import com.example.binderdemo.IAsyncWorker;
import com.example.binderdemo.IResultCallback;
import com.example.binderdemo.ISyncResultCallback;

interface ICalculator {
    int add(int a, int b);
    oneway void notifyValue(int requestId, int value);
    oneway void notifyValueViaHandler(int requestId, int value);
    void registerCallback(IResultCallback callback);
    int addAndCallback(int requestId, int a, int b, ISyncResultCallback callback);
    IAsyncWorker getAsyncWorker(int workerId);
    int addWithRequestId(int requestId, int a, int b, boolean injectHandlerBlocker);
}
