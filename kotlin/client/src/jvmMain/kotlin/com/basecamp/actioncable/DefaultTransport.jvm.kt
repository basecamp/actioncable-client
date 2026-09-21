package com.basecamp.actioncable

actual fun defaultTransport(): Transport = WebSocketTransport()
