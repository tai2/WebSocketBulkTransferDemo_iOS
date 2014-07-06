# WebSocketBulkTransferDemo for iOS

## What is this?

An experiment on bulk data transfer from native codo to JavaScript in WebView using WebSocket.

## Features

 * In-app minimum WebSocket server only works for this demonstration.
 * 1MB payload size buffered up to 10MB.
 * Data buffer is filled at 100ms interval. 
 * Data in buffer is sent until socket buffer is filled up continuously.

## Problem

 * WebSocket received data accumrates increasingly and are not released. Finally, this causes the app crashes.

## Result

 * About 110 Mbps recorded at 1MB chunk on 1G iPad mini.
 * Because of the problem, this way is not useful.
