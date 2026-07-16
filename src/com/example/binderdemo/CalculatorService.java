package com.example.binderdemo;

import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Process;
import android.os.RemoteCallbackList;
import android.os.RemoteException;
import android.os.SystemClock;
import android.os.Trace;
import android.util.Log;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

public final class CalculatorService extends Service {
    private static final String TAG = "BinderLab";
    private static final long HANDLER_BLOCK_MS = 1500;
    private static final long SAME_NODE_HOLD_MS = 300;
    private static final long CROSS_NODE_HOLD_MS = 700;

    private final RemoteCallbackList<IResultCallback> callbacks =
            new RemoteCallbackList<>();
    private final IAsyncWorker asyncWorker1 = createAsyncWorker(1);
    private final IAsyncWorker asyncWorker2 = createAsyncWorker(2);
    private HandlerThread workerThread;
    private Handler worker;

    private final ICalculator.Stub binder = new ICalculator.Stub() {
        @Override
        public int add(int a, int b) {
            return a + b;
        }

        @Override
        public int addWithRequestId(
                int requestId,
                int a,
                int b,
                boolean injectHandlerBlocker) {
            final int directCallingUid = Binder.getCallingUid();
            final long s0 = SystemClock.elapsedRealtimeNanos();
            Log.i(TAG, point("S0",
                    "requestId=" + requestId
                            + " atNs=" + s0
                            + " callingUid=" + directCallingUid
                            + " injectHandlerBlocker=" + injectHandlerBlocker));
            Trace.beginSection("BinderLab#server-add");
            try {
                CountDownLatch done = new CountDownLatch(1);
                CountDownLatch postReturned = new CountDownLatch(1);
                AtomicInteger result = new AtomicInteger();
                AtomicReference<RuntimeException> handlerFailure =
                        new AtomicReference<>();

                // Lab-only fault injection: occupy the same Handler before the real task.
                // Never copy deliberate queue blocking into production service code.
                if (injectHandlerBlocker && !worker.post(() -> {
                    Trace.beginSection("BinderLab#handler-blocker");
                    try {
                        SystemClock.sleep(HANDLER_BLOCK_MS);
                    } finally {
                        Trace.endSection();
                    }
                })) {
                    throw new IllegalStateException("worker rejected handler blocker");
                }

                AtomicLong h0bRef = new AtomicLong(-1L);
                final long h0a = SystemClock.elapsedRealtimeNanos();
                boolean accepted = worker.post(() -> {
                    try {
                        if (!postReturned.await(1, TimeUnit.SECONDS)) {
                            throw new IllegalStateException(
                                    "post-return instrumentation timeout");
                        }
                        long h1 = SystemClock.elapsedRealtimeNanos();
                        long h0b = h0bRef.get();
                        long queueNs = h1 - h0b;
                        Log.i(TAG, point("H1",
                                "requestId=" + requestId
                                        + " atNs=" + h1
                                        + " queueNs=" + queueNs));
                        Trace.beginSection("BinderLab#handler-add");
                        try {
                            result.set(a + b);
                        } finally {
                            Trace.endSection();
                            long h2 = SystemClock.elapsedRealtimeNanos();
                            Log.i(TAG, point("H2",
                                    "requestId=" + requestId
                                            + " atNs=" + h2
                                            + " runNs=" + (h2 - h1)));
                        }
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        handlerFailure.set(new IllegalStateException(
                                "handler thread interrupted", interrupted));
                    } catch (RuntimeException failure) {
                        handlerFailure.set(failure);
                    } finally {
                        done.countDown();
                    }
                });
                final long h0b = SystemClock.elapsedRealtimeNanos();
                h0bRef.set(h0b);
                Log.i(TAG, point("H0A",
                        "requestId=" + requestId + " atNs=" + h0a));
                Log.i(TAG, point("H0B",
                        "requestId=" + requestId
                                + " atNs=" + h0b
                                + " postAccepted=" + accepted
                                + " injectHandlerBlocker=" + injectHandlerBlocker
                                + " postCallNs=" + (h0b - h0a)));
                postReturned.countDown();
                if (!accepted) {
                    throw new IllegalStateException("worker rejected handler add");
                }

                if (!done.await(5, TimeUnit.SECONDS)) {
                    throw new IllegalStateException("handler timeout");
                }
                if (handlerFailure.get() != null) {
                    throw handlerFailure.get();
                }
                return result.get();
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("binder thread interrupted", interrupted);
            } finally {
                Trace.endSection();
                long s1 = SystemClock.elapsedRealtimeNanos();
                Log.i(TAG, point("S1",
                        "requestId=" + requestId
                                + " atNs=" + s1
                                + " serverNs=" + (s1 - s0)));
            }
        }

        @Override
        public void notifyValue(int requestId, int value) {
            // Lab-only: deliberately blocks a Binder thread to expose async ordering.
            // Never copy this into production oneway handlers.
            long begin = SystemClock.elapsedRealtimeNanos();
            Log.i(TAG, point("S_ONEWAY_ENTER",
                    "node=ICalculator"
                            + " requestId=" + requestId
                            + " value=" + value
                            + " begin=" + begin));
            SystemClock.sleep(SAME_NODE_HOLD_MS);
            long end = SystemClock.elapsedRealtimeNanos();
            Log.i(TAG, point("S_ONEWAY_EXIT",
                    "node=ICalculator"
                            + " requestId=" + requestId
                            + " value=" + value
                            + " end=" + end
                            + " runNs=" + (end - begin)));
        }

        @Override
        public void notifyValueViaHandler(int requestId, int value) {
            Log.i(TAG, point("S_HANDLER_POST",
                    "requestId=" + requestId + " value=" + value));
            if (!worker.post(() -> {
                Log.i(TAG, point("S_HANDLER_RUN",
                        "requestId=" + requestId + " value=" + value));
                broadcastResult(requestId, value);
            })) {
                Log.w(TAG, point("S_HANDLER_POST_FAILED",
                        "requestId=" + requestId + " value=" + value));
            }
        }

        @Override
        public void registerCallback(IResultCallback callback) {
            if (callback == null) {
                throw new IllegalArgumentException("callback must not be null");
            }
            if (!callbacks.register(callback)) {
                throw new IllegalStateException("callback registration rejected");
            }
            Log.i(TAG, point("S_REGISTER_CALLBACK",
                    "callbackClass=" + callback.getClass().getName()
                            + " callbackBinderClass="
                            + callback.asBinder().getClass().getName()));
        }

        @Override
        public int addAndCallback(
                int requestId,
                int a,
                int b,
                ISyncResultCallback callback) throws RemoteException {
            if (callback == null) {
                throw new IllegalArgumentException("callback must not be null");
            }
            int result = a + b;
            long beforeCallbackAtNs = SystemClock.elapsedRealtimeNanos();
            Log.i(TAG, point("S_BEFORE_SYNC_CALLBACK",
                    "requestId=" + requestId
                            + " result=" + result
                            + " atNs=" + beforeCallbackAtNs));
            int callbackResult = callback.onResult(requestId, result);
            long afterCallbackAtNs = SystemClock.elapsedRealtimeNanos();
            Log.i(TAG, point("S_AFTER_SYNC_CALLBACK",
                    "requestId=" + requestId
                            + " callbackResult=" + callbackResult
                            + " atNs=" + afterCallbackAtNs));
            return result;
        }

        @Override
        public IAsyncWorker getAsyncWorker(int workerId) {
            if (workerId == 1) {
                return asyncWorker1;
            }
            if (workerId == 2) {
                return asyncWorker2;
            }
            throw new IllegalArgumentException("workerId must be 1 or 2");
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        workerThread = new HandlerThread("CalculatorWorker");
        workerThread.start();
        worker = new Handler(workerThread.getLooper());
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    @Override
    public void onDestroy() {
        callbacks.kill();
        if (workerThread != null) {
            workerThread.quitSafely();
        }
        super.onDestroy();
    }

    private IAsyncWorker createAsyncWorker(final int workerId) {
        return new IAsyncWorker.Stub() {
            @Override
            public void work(int requestId, int value) {
                // Lab-only: two Stub instances create two distinct Binder nodes.
                // The delay makes any allowed cross-node overlap visible in logs.
                long begin = SystemClock.elapsedRealtimeNanos();
                Log.i(TAG, point("S_ASYNC_WORKER_ENTER",
                        "node=N" + workerId
                                + " requestId=" + requestId
                                + " value=" + value
                                + " begin=" + begin));
                SystemClock.sleep(CROSS_NODE_HOLD_MS);
                long end = SystemClock.elapsedRealtimeNanos();
                Log.i(TAG, point("S_ASYNC_WORKER_EXIT",
                        "node=N" + workerId
                                + " requestId=" + requestId
                                + " value=" + value
                                + " end=" + end
                                + " runNs=" + (end - begin)));
            }
        };
    }

    private void broadcastResult(int requestId, int value) {
        int count = callbacks.beginBroadcast();
        try {
            for (int i = 0; i < count; i++) {
                try {
                    callbacks.getBroadcastItem(i).onResult(requestId, value);
                } catch (RemoteException deadClient) {
                    Log.w(TAG, point("S_CALLBACK_FAILED",
                            "requestId=" + requestId + " " + deadClient));
                }
            }
        } finally {
            callbacks.finishBroadcast();
        }
    }

    private static String point(String marker, String detail) {
        String timedDetail = detail.startsWith("atNs=") || detail.contains(" atNs=")
                ? detail
                : detail + " atNs=" + SystemClock.elapsedRealtimeNanos();
        return marker
                + " pid=" + Process.myPid()
                + " tid=" + Process.myTid()
                + " thread=" + Thread.currentThread().getName()
                + " " + timedDetail;
    }
}
