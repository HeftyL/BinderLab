package com.example.binderdemo;

interface IResultCallback {
    oneway void onResult(int requestId, int value);
}
