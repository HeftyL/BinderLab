package com.example.binderdemo;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.DeadObjectException;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Process;
import android.os.RemoteException;
import android.os.SystemClock;
import android.os.Trace;
import android.util.Log;
import android.widget.TextView;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

public final class MainActivity extends Activity {
    private static final String TAG = "BinderLab";
    private static final String EXTRA_EXPERIMENT = "experiment";
    private static final String EXPERIMENT_HANDLER_LATENCY_BASELINE =
            "handler-latency-baseline";
    private static final String EXPERIMENT_HANDLER_LATENCY_BLOCKED =
            "handler-latency-blocked";
    private static final String EXPERIMENT_SYNC_REENTRY = "sync-reentry";
    private static final String EXPERIMENT_ONEWAY_SAME_NODE = "oneway-same-node";
    private static final String EXPERIMENT_ONEWAY_CROSS_NODE = "oneway-cross-node";
    private static final String EXPERIMENT_ASYNC_CALLBACK = "async-callback";
    private static final String EXPERIMENT_BINDER_DEATH = "binder-death";
    private static final AtomicLong NEXT_CONNECTION_EPOCH = new AtomicLong();
    private static final AtomicLong NEXT_GENERATION_ID = new AtomicLong();

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Object generationLock = new Object();
    private final AtomicReference<ClientGeneration> generationRef =
            new AtomicReference<>();
    private final AtomicReference<SyncCallContext> syncCallRef =
            new AtomicReference<>();
    private final AtomicReference<AsyncWaiter> asyncWaiterRef =
            new AtomicReference<>();
    private final AtomicBoolean experimentStarted = new AtomicBoolean();
    private final AtomicInteger requestIds = new AtomicInteger(1000);
    private TextView statusView;
    private String selectedExperiment;
    private ServiceConnection connection;
    private long connectionEpoch;
    private boolean bound;

    private final IResultCallback callback = new IResultCallback.Stub() {
        @Override
        public void onResult(int requestId, int value) {
            AsyncWaiter waiter = asyncWaiterRef.get();
            boolean requestMatches = waiter != null && waiter.requestId == requestId;
            Log.i(TAG, point("C_CALLBACK",
                    "requestId=" + requestId
                            + " value=" + value
                            + " requestMatches=" + requestMatches));
            if (requestMatches) {
                waiter.done.countDown();
            }
            mainHandler.post(() -> append(
                    "callback requestId=" + requestId + " value=" + value));
        }
    };

    private final ISyncResultCallback syncCallback = new ISyncResultCallback.Stub() {
        @Override
        public int onResult(int requestId, int value) {
            long callbackAtNs = SystemClock.elapsedRealtimeNanos();
            int callbackTid = Process.myTid();
            SyncCallContext context = syncCallRef.get();
            boolean requestMatches = context != null && context.requestId == requestId;
            int waitingTid = context != null ? context.callerTid : -1;
            boolean insideOuterCall = requestMatches;
            boolean reusedWaitingThread = insideOuterCall && callbackTid == waitingTid;
            Log.i(TAG, point("C_SYNC_CALLBACK",
                    "requestId=" + requestId
                            + " value=" + value
                            + " requestMatches=" + requestMatches
                             + " insideOuterCall=" + insideOuterCall
                             + " waitingTid=" + waitingTid
                            + " reusedWaitingThread=" + reusedWaitingThread
                            + " atNs=" + callbackAtNs));
            return value * 2;
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        selectedExperiment = normalizeExperiment(
                getIntent().getStringExtra(EXTRA_EXPERIMENT));

        statusView = new TextView(this);
        statusView.setTextSize(16f);
        statusView.setPadding(32, 32, 32, 32);
        statusView.setText("BinderLab API 36\n");
        setContentView(statusView);

        if (selectedExperiment == null) {
            append("Select one isolated mode:");
            append(EXPERIMENT_HANDLER_LATENCY_BASELINE);
            append(EXPERIMENT_HANDLER_LATENCY_BLOCKED);
            append(EXPERIMENT_SYNC_REENTRY);
            append(EXPERIMENT_ONEWAY_SAME_NODE);
            append(EXPERIMENT_ONEWAY_CROSS_NODE);
            append(EXPERIMENT_ASYNC_CALLBACK);
            append(EXPERIMENT_BINDER_DEATH);
        } else {
            append("experiment=" + selectedExperiment);
        }

        Intent intent = new Intent(this, CalculatorService.class);
        connectionEpoch = NEXT_CONNECTION_EPOCH.incrementAndGet();
        connection = createConnection(connectionEpoch);
        bound = bindService(intent, connection, Context.BIND_AUTO_CREATE);
        if (!bound) {
            append("bindService returned false");
        }
    }

    private ServiceConnection createConnection(final long epoch) {
        return new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder service) {
                if (!bound || epoch != connectionEpoch) {
                    Log.w(TAG, point("C_CONNECTION_CALLBACK_IGNORED",
                            "connectionEpoch=" + epoch
                                    + " currentConnectionEpoch=" + connectionEpoch
                                    + " reason=stale onServiceConnected"));
                    return;
                }

                ICalculator calculator = ICalculator.Stub.asInterface(service);
                ClientGeneration candidate = new ClientGeneration(
                        epoch,
                        NEXT_GENERATION_ID.incrementAndGet(),
                        service,
                        calculator);
                logGenerationTransition(
                        "C_GENERATION_STATE",
                        candidate,
                        null,
                        GenerationState.CONNECTING,
                        "onServiceConnected");

                try {
                    service.linkToDeath(candidate.deathRecipient, 0);
                    if (!advanceGeneration(
                            candidate,
                            GenerationState.CONNECTING,
                            GenerationState.LINKED,
                            "linkToDeath succeeded")) {
                        unlinkGeneration(candidate);
                        return;
                    }

                    calculator.registerCallback(callback);
                    if (!advanceGeneration(
                            candidate,
                            GenerationState.LINKED,
                            GenerationState.REGISTERED,
                            "callback registered")) {
                        unlinkGeneration(candidate);
                        return;
                    }
                } catch (RemoteException alreadyDead) {
                    Log.w(TAG, point("C_REGISTER_FAILED",
                            generationDetail(candidate)
                                    + " reason=" + alreadyDead));
                    invalidateGeneration(candidate, "registration failed");
                    return;
                } catch (RuntimeException registrationFailure) {
                    Log.w(TAG, point("C_REGISTER_FAILED",
                            generationDetail(candidate)
                                    + " reason=" + registrationFailure));
                    invalidateGeneration(candidate, "registration runtime failure");
                    return;
                }

                if (!publishActiveGeneration(candidate)) {
                    unlinkGeneration(candidate);
                    return;
                }
                if (!isActive(candidate)) {
                    return;
                }

                append("connected ACTIVE generation=" + candidate.generationId
                        + ": " + calculator.getClass().getName());
                Log.i(TAG, point("C_CONNECTED_ACTIVE",
                        generationDetail(candidate)
                                + " calculatorClass="
                                + calculator.getClass().getName()
                                + " calculatorBinderClass="
                                + calculator.asBinder().getClass().getName()));
                if (selectedExperiment == null) {
                    append("no experiment selected; use --es experiment <mode>");
                    return;
                }
                if (!experimentStarted.compareAndSet(false, true)) {
                    Log.i(TAG, point("C_EXPERIMENT_NOT_RESTARTED",
                            "mode=" + selectedExperiment
                                    + " " + generationDetail(candidate)
                                    + " reason=activity-experiment-is-one-shot"));
                    return;
                }
                new Thread(
                        () -> runSelectedExperiment(candidate),
                        "BinderLab-" + selectedExperiment).start();
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {
                invalidateCurrentForConnection(epoch, "service disconnected");
            }

            @Override
            public void onBindingDied(ComponentName name) {
                invalidateCurrentForConnection(epoch, "binding died");
            }

            @Override
            public void onNullBinding(ComponentName name) {
                invalidateCurrentForConnection(epoch, "null binding");
            }
        };
    }

    private void runSelectedExperiment(ClientGeneration generation) {
        if (!isActive(generation)) {
            return;
        }
        ICalculator local = generation.calculator;
        Log.i(TAG, point("C_EXPERIMENT_BEGIN", "mode=" + selectedExperiment));
        try {
            if (EXPERIMENT_HANDLER_LATENCY_BASELINE.equals(selectedExperiment)) {
                runHandlerLatency(local, false);
            } else if (EXPERIMENT_HANDLER_LATENCY_BLOCKED.equals(selectedExperiment)) {
                runHandlerLatency(local, true);
            } else if (EXPERIMENT_SYNC_REENTRY.equals(selectedExperiment)) {
                runSyncReentry(local);
            } else if (EXPERIMENT_ONEWAY_SAME_NODE.equals(selectedExperiment)) {
                runOnewaySameNode(local);
            } else if (EXPERIMENT_ONEWAY_CROSS_NODE.equals(selectedExperiment)) {
                runOnewayCrossNode(local);
            } else if (EXPERIMENT_ASYNC_CALLBACK.equals(selectedExperiment)) {
                runAsyncCallback(local);
            } else if (EXPERIMENT_BINDER_DEATH.equals(selectedExperiment)) {
                runDeathLastSuccess(local);
                Log.i(TAG, point("C_DEATH_EXPERIMENT_ARMED",
                        generationDetail(generation)
                                + " note=host must kill the remote process"));
            }
            Log.i(TAG, point("C_EXPERIMENT_CLIENT_DONE",
                    "mode=" + selectedExperiment));
        } catch (RemoteException failure) {
            Log.e(TAG, point("C_CALL_FAILED", failure.toString()));
            invalidateGeneration(generation, "RemoteException");
            mainHandler.post(() -> append("call failed: " + failure));
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            Log.e(TAG, point("C_EXPERIMENT_INTERRUPTED", interrupted.toString()));
        } catch (RuntimeException serviceFailure) {
            Log.e(TAG, point("C_SERVICE_ERROR", serviceFailure.toString()));
            mainHandler.post(() -> append("service error: " + serviceFailure));
        }
    }

    private void runHandlerLatency(ICalculator local, boolean injectHandlerBlocker)
            throws RemoteException {
        int requestId = requestIds.incrementAndGet();
        Trace.beginSection("BinderLab#client-add");
        long c0 = SystemClock.elapsedRealtimeNanos();
        try {
            Log.i(TAG, point("C0",
                    "requestId=" + requestId
                            + " atNs=" + c0
                            + " injectHandlerBlocker=" + injectHandlerBlocker));
            int result = local.addWithRequestId(
                    requestId, 1, 2, injectHandlerBlocker);
            long c1 = SystemClock.elapsedRealtimeNanos();
            Log.i(TAG, point("C1",
                    "requestId=" + requestId
                            + " atNs=" + c1
                            + " result=" + result
                            + " costNs=" + (c1 - c0)));
            mainHandler.post(() -> append("add result=" + result));
        } catch (RuntimeException failure) {
            long c1 = SystemClock.elapsedRealtimeNanos();
            Log.e(TAG, point("C1",
                    "requestId=" + requestId
                            + " atNs=" + c1
                            + " error=" + failure
                            + " costNs=" + (c1 - c0)));
            throw failure;
        } finally {
            Trace.endSection();
        }
    }

    private void runSyncReentry(ICalculator local) throws RemoteException {
        int requestId = requestIds.incrementAndGet();
        int callerTid = Process.myTid();
        SyncCallContext context = new SyncCallContext(requestId, callerTid);
        if (!syncCallRef.compareAndSet(null, context)) {
            throw new IllegalStateException("another sync experiment is active");
        }
        long beginAtNs = SystemClock.elapsedRealtimeNanos();
        Log.i(TAG, point("C_SYNC_CALL_BEGIN",
                "requestId=" + requestId
                        + " callerTid=" + callerTid
                        + " atNs=" + beginAtNs));
        try {
            int result = local.addAndCallback(requestId, 2, 3, syncCallback);
            long endAtNs = SystemClock.elapsedRealtimeNanos();
            Log.i(TAG, point("C_SYNC_CALL_END",
                    "requestId=" + requestId
                            + " result=" + result
                            + " atNs=" + endAtNs));
        } catch (RemoteException | RuntimeException failure) {
            long endAtNs = SystemClock.elapsedRealtimeNanos();
            Log.i(TAG, point("C_SYNC_CALL_END",
                    "requestId=" + requestId
                            + " error=" + failure
                            + " atNs=" + endAtNs));
            throw failure;
        } finally {
            syncCallRef.compareAndSet(context, null);
        }
    }

    private void runOnewaySameNode(ICalculator local) throws RemoteException {
        int requestId1 = requestIds.incrementAndGet();
        int requestId2 = requestIds.incrementAndGet();
        int requestId3 = requestIds.incrementAndGet();
        Log.i(TAG, point("C_ONEWAY_BURST_BEGIN",
                "node=ICalculator requestIds="
                        + requestId1 + "," + requestId2 + "," + requestId3));
        callSameNode(local, requestId1, 1);
        callSameNode(local, requestId2, 2);
        callSameNode(local, requestId3, 3);
        Log.i(TAG, point("C_ONEWAY_BURST_RETURN",
                "note=all transact calls returned; server completion is not implied"));
    }

    private void runOnewayCrossNode(ICalculator local)
            throws RemoteException, InterruptedException {
        IAsyncWorker worker1 = local.getAsyncWorker(1);
        IAsyncWorker worker2 = local.getAsyncWorker(2);
        if (worker1 == null || worker2 == null) {
            throw new IllegalStateException("service returned a null async worker");
        }

        int requestId1 = requestIds.incrementAndGet();
        int requestId2 = requestIds.incrementAndGet();
        int requestId3 = requestIds.incrementAndGet();
        int requestId4 = requestIds.incrementAndGet();
        CountDownLatch ready = new CountDownLatch(2);
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch submitted = new CountDownLatch(2);
        AtomicReference<Throwable> senderFailure = new AtomicReference<>();

        Thread n1Sender = new Thread(() -> {
            ready.countDown();
            try {
                start.await();
                callAsyncWorker(1, worker1, requestId1, 1);
                callAsyncWorker(1, worker1, requestId2, 2);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                senderFailure.compareAndSet(null, interrupted);
            } catch (RemoteException | RuntimeException failure) {
                senderFailure.compareAndSet(null, failure);
            } finally {
                submitted.countDown();
            }
        }, "BinderLab-N1-sender");

        Thread n2Sender = new Thread(() -> {
            ready.countDown();
            try {
                start.await();
                callAsyncWorker(2, worker2, requestId3, 3);
                callAsyncWorker(2, worker2, requestId4, 4);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                senderFailure.compareAndSet(null, interrupted);
            } catch (RemoteException | RuntimeException failure) {
                senderFailure.compareAndSet(null, failure);
            } finally {
                submitted.countDown();
            }
        }, "BinderLab-N2-sender");

        n1Sender.start();
        n2Sender.start();
        if (!ready.await(2, TimeUnit.SECONDS)) {
            start.countDown();
            throw new IllegalStateException("concurrent senders did not become ready");
        }
        Log.i(TAG, point("C_CROSS_NODE_RELEASE",
                "n1RequestIds=" + requestId1 + "," + requestId2
                        + " n2RequestIds=" + requestId3 + "," + requestId4));
        start.countDown();
        if (!submitted.await(5, TimeUnit.SECONDS)) {
            throw new IllegalStateException("oneway submission timeout");
        }
        if (senderFailure.get() != null) {
            throw new IllegalStateException("oneway sender failed", senderFailure.get());
        }
        Log.i(TAG, point("C_CROSS_NODE_RETURN",
                "note=all transact calls returned; inspect server intervals"));
    }

    private void callSameNode(ICalculator local, int requestId, int value)
            throws RemoteException {
        long begin = SystemClock.elapsedRealtimeNanos();
        Log.i(TAG, point("C_SAME_NODE_CALL_BEGIN",
                "requestId=" + requestId + " atNs=" + begin));
        local.notifyValue(requestId, value);
        long returned = SystemClock.elapsedRealtimeNanos();
        Log.i(TAG, point("C_SAME_NODE_CALL_RETURN",
                "requestId=" + requestId
                        + " atNs=" + returned
                        + " callNs=" + (returned - begin)));
    }

    private void callAsyncWorker(
            int node,
            IAsyncWorker worker,
            int requestId,
            int value) throws RemoteException {
        long begin = SystemClock.elapsedRealtimeNanos();
        Log.i(TAG, point("C_N" + node + "_CALL_BEGIN",
                "requestId=" + requestId + " atNs=" + begin));
        worker.work(requestId, value);
        long returned = SystemClock.elapsedRealtimeNanos();
        Log.i(TAG, point("C_N" + node + "_CALL_RETURN",
                "requestId=" + requestId
                        + " atNs=" + returned
                        + " callNs=" + (returned - begin)));
    }

    private void runAsyncCallback(ICalculator local)
            throws RemoteException, InterruptedException {
        int requestId = requestIds.incrementAndGet();
        AsyncWaiter waiter = new AsyncWaiter(requestId);
        if (!asyncWaiterRef.compareAndSet(null, waiter)) {
            throw new IllegalStateException("another async experiment is active");
        }
        try {
            Log.i(TAG, point("C_ASYNC_CALL_BEGIN", "requestId=" + requestId));
            local.notifyValueViaHandler(requestId, 7);
                    Log.i(TAG, point("C_ASYNC_CALL_RETURN",
                            "requestId=" + requestId
                                    + " completion=server Handler/callback may still be pending"));
            if (!waiter.done.await(5, TimeUnit.SECONDS)) {
                throw new IllegalStateException("async callback timeout");
            }
            Log.i(TAG, point("C_ASYNC_CALLBACK_OBSERVED",
                    "requestId=" + requestId));
        } finally {
            asyncWaiterRef.compareAndSet(waiter, null);
        }
    }

    private void runDeathLastSuccess(ICalculator local) throws RemoteException {
        int requestId = requestIds.incrementAndGet();
        long begin = SystemClock.elapsedRealtimeNanos();
        Log.i(TAG, point("C_LAST_SUCCESS_BEGIN",
                "requestId=" + requestId + " atNs=" + begin));
        int result = local.addWithRequestId(requestId, 40, 2, false);
        long end = SystemClock.elapsedRealtimeNanos();
        Log.i(TAG, point("C_LAST_SUCCESS_END",
                "requestId=" + requestId
                        + " atNs=" + end
                        + " result=" + result));
    }

    private boolean advanceGeneration(
            ClientGeneration generation,
            GenerationState expected,
            GenerationState next,
            String reason) {
        synchronized (generationLock) {
            if (generation.state != expected) {
                Log.w(TAG, point("C_GENERATION_TRANSITION_REJECTED",
                        generationDetail(generation)
                                + " expected=" + expected
                                + " requested=" + next
                                + " reason=" + reason));
                return false;
            }
            generation.state = next;
            logGenerationTransition(
                    "C_GENERATION_STATE", generation, expected, next, reason);
        }
        return true;
    }

    private boolean publishActiveGeneration(ClientGeneration candidate) {
        ClientGeneration previous;
        synchronized (generationLock) {
            if (candidate.state != GenerationState.REGISTERED) {
                return false;
            }
            candidate.state = GenerationState.ACTIVE;
            previous = generationRef.getAndSet(candidate);
            logGenerationTransition(
                    "C_GENERATION_STATE",
                    candidate,
                    GenerationState.REGISTERED,
                    GenerationState.ACTIVE,
                    "published to readers");
        }
        if (previous != null && previous != candidate) {
            retireGeneration(previous, "replaced by new ACTIVE generation");
        }
        return true;
    }

    private ClientGeneration getActiveGeneration() {
        synchronized (generationLock) {
            ClientGeneration current = generationRef.get();
            if (current == null || current.state != GenerationState.ACTIVE) {
                return null;
            }
            return current;
        }
    }

    private boolean isActive(ClientGeneration expected) {
        synchronized (generationLock) {
            return generationRef.get() == expected
                    && expected.state == GenerationState.ACTIVE;
        }
    }

    private boolean invalidateGeneration(ClientGeneration expected, String reason) {
        GenerationState oldState;
        boolean wasCurrent;
        synchronized (generationLock) {
            oldState = expected.state;
            if (oldState == GenerationState.INVALID) {
                return false;
            }
            expected.state = GenerationState.INVALID;
            wasCurrent = generationRef.compareAndSet(expected, null);
        }
        unlinkGeneration(expected);
        Log.w(TAG, point("C_GENERATION_INVALID",
                generationDetail(expected)
                        + " oldState=" + oldState
                        + " newState=" + GenerationState.INVALID
                        + " wasCurrent=" + wasCurrent
                         + " reason=" + reason));
        mainHandler.post(() -> append("generation invalid: " + reason));
        return wasCurrent;
    }

    private void invalidateCurrentForConnection(long epoch, String reason) {
        ClientGeneration current = getActiveGeneration();
        if (current != null && current.connectionEpoch == epoch) {
            invalidateGeneration(current, reason);
            return;
        }
        Log.i(TAG, point("C_CONNECTION_CALLBACK_IGNORED",
                "connectionEpoch=" + epoch
                        + " current=" + (current == null
                        ? "none"
                        : generationDetail(current))
                        + " reason=" + reason));
    }

    private void retireGeneration(ClientGeneration generation, String reason) {
        GenerationState oldState;
        synchronized (generationLock) {
            oldState = generation.state;
            generation.state = GenerationState.INVALID;
        }
        unlinkGeneration(generation);
        Log.i(TAG, point("C_GENERATION_RETIRED",
                generationDetail(generation)
                        + " oldState=" + oldState
                        + " newState=" + GenerationState.INVALID
                        + " reason=" + reason));
    }

    private void unlinkGeneration(ClientGeneration generation) {
        try {
            boolean removed = generation.binder.unlinkToDeath(generation.deathRecipient, 0);
            Log.i(TAG, point("C_UNLINK_TO_DEATH",
                    generationDetail(generation) + " removed=" + removed));
        } catch (RuntimeException unavailable) {
            Log.i(TAG, point("C_UNLINK_TO_DEATH",
                    generationDetail(generation)
                            + " bestEffortFailure="
                            + unavailable.getClass().getSimpleName()));
        }
    }

    private void probeDeadProxy(ClientGeneration generation) {
        new Thread(() -> {
            int requestId = requestIds.incrementAndGet();
            Log.i(TAG, point("C_OLD_PROXY_PROBE_BEGIN",
                    generationDetail(generation) + " requestId=" + requestId));
            try {
                int result = generation.calculator.addWithRequestId(
                        requestId, 1, 2, false);
                Log.w(TAG, point("C_OLD_PROXY_PROBE_UNEXPECTED_SUCCESS",
                        generationDetail(generation)
                                + " requestId=" + requestId
                                + " result=" + result));
            } catch (DeadObjectException expected) {
                Log.i(TAG, point("C_OLD_PROXY_DEAD_OBJECT",
                        generationDetail(generation)
                                + " requestId=" + requestId
                                + " exception=" + expected.getClass().getSimpleName()));
            } catch (RemoteException remoteFailure) {
                Log.i(TAG, point("C_OLD_PROXY_REMOTE_FAILURE",
                        generationDetail(generation)
                                + " requestId=" + requestId
                                + " exception="
                                + remoteFailure.getClass().getSimpleName()));
            } catch (RuntimeException runtimeFailure) {
                Log.w(TAG, point("C_OLD_PROXY_RUNTIME_FAILURE",
                        generationDetail(generation)
                                + " requestId=" + requestId
                                + " exception="
                                + runtimeFailure.getClass().getSimpleName()));
            } finally {
                scheduleDeathExperimentRebind(generation);
            }
        }, "BinderLab-dead-proxy-probe").start();
    }

    private void scheduleDeathExperimentRebind(ClientGeneration deadGeneration) {
        if (!EXPERIMENT_BINDER_DEATH.equals(selectedExperiment)) {
            return;
        }
        mainHandler.post(() -> {
            if (!bound
                    || connection == null
                    || connectionEpoch != deadGeneration.connectionEpoch) {
                Log.i(TAG, point("C_TEST_REBIND_SKIPPED",
                        generationDetail(deadGeneration)
                                + " currentConnectionEpoch=" + connectionEpoch
                                + " bound=" + bound));
                return;
            }

            ServiceConnection oldConnection = connection;
            long oldEpoch = connectionEpoch;
            bound = false;
            try {
                unbindService(oldConnection);
            } catch (RuntimeException alreadyUnbound) {
                Log.i(TAG, point("C_TEST_UNBIND_BEST_EFFORT",
                        "connectionEpoch=" + oldEpoch
                                + " exception="
                                + alreadyUnbound.getClass().getSimpleName()));
            }

            connectionEpoch = NEXT_CONNECTION_EPOCH.incrementAndGet();
            connection = createConnection(connectionEpoch);
            Log.i(TAG, point("C_TEST_REBIND_BEGIN",
                    "oldConnectionEpoch=" + oldEpoch
                            + " newConnectionEpoch=" + connectionEpoch
                            + " reason=binder-death experiment"));
            Intent intent = new Intent(this, CalculatorService.class);
            bound = bindService(intent, connection, Context.BIND_AUTO_CREATE);
            Log.i(TAG, point("C_TEST_REBIND_RESULT",
                    "connectionEpoch=" + connectionEpoch + " bound=" + bound));
            if (!bound) {
                append("binder-death test rebind failed");
            }
        });
    }

    private void logGenerationTransition(
            String marker,
            ClientGeneration generation,
            GenerationState oldState,
            GenerationState newState,
            String reason) {
        Log.i(TAG, point(marker,
                generationDetail(generation)
                        + " oldState=" + (oldState == null ? "NONE" : oldState)
                        + " newState=" + newState
                        + " reason=" + reason));
    }

    private static String generationDetail(ClientGeneration generation) {
        return "connectionEpoch=" + generation.connectionEpoch
                + " generationId=" + generation.generationId
                + " binderIdentity=" + generation.binderIdentity;
    }

    @Override
    protected void onDestroy() {
        ClientGeneration generation;
        synchronized (generationLock) {
            generation = generationRef.getAndSet(null);
            if (generation != null) {
                generation.state = GenerationState.INVALID;
            }
        }
        if (generation != null) {
            unlinkGeneration(generation);
        }
        if (bound && connection != null) {
            unbindService(connection);
            bound = false;
        }
        super.onDestroy();
    }

    private static String normalizeExperiment(String experiment) {
        if (EXPERIMENT_HANDLER_LATENCY_BASELINE.equals(experiment)
                || EXPERIMENT_HANDLER_LATENCY_BLOCKED.equals(experiment)
                || EXPERIMENT_SYNC_REENTRY.equals(experiment)
                || EXPERIMENT_ONEWAY_SAME_NODE.equals(experiment)
                || EXPERIMENT_ONEWAY_CROSS_NODE.equals(experiment)
                || EXPERIMENT_ASYNC_CALLBACK.equals(experiment)
                || EXPERIMENT_BINDER_DEATH.equals(experiment)) {
            return experiment;
        }
        return null;
    }

    private void append(String text) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(() -> append(text));
            return;
        }
        statusView.append(text + "\n");
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

    private enum GenerationState {
        CONNECTING,
        LINKED,
        REGISTERED,
        ACTIVE,
        INVALID
    }

    private final class ClientGeneration {
        final long connectionEpoch;
        final long generationId;
        final IBinder binder;
        final ICalculator calculator;
        final IBinder.DeathRecipient deathRecipient;
        final String binderIdentity;
        volatile GenerationState state = GenerationState.CONNECTING;

        ClientGeneration(
                long connectionEpoch,
                long generationId,
                IBinder binder,
                ICalculator calculator) {
            this.connectionEpoch = connectionEpoch;
            this.generationId = generationId;
            this.binder = binder;
            this.calculator = calculator;
            this.binderIdentity = binder.getClass().getName()
                    + "@" + Integer.toHexString(System.identityHashCode(binder));
            this.deathRecipient = () -> {
                if (invalidateGeneration(this, "binderDied")) {
                    probeDeadProxy(this);
                } else {
                    Log.i(TAG, point("C_STALE_DEATH_IGNORED",
                            generationDetail(this)
                                    + " state=" + state
                                    + " reason=not-current-active-generation"));
                }
            };
        }
    }

    private static final class SyncCallContext {
        final int requestId;
        final int callerTid;

        SyncCallContext(int requestId, int callerTid) {
            this.requestId = requestId;
            this.callerTid = callerTid;
        }
    }

    private static final class AsyncWaiter {
        final int requestId;
        final CountDownLatch done = new CountDownLatch(1);

        AsyncWaiter(int requestId) {
            this.requestId = requestId;
        }
    }
}
