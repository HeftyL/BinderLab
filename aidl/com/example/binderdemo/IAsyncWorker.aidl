package com.example.binderdemo;

interface IAsyncWorker {
    oneway void work(int requestId, int value);
}
