# Proxy

This was an aborted attempt to rewrite the current (production) Go Proxy (Proxy v2) in Ruby with Async.

Async is not mature enough. It doesn't HTTP server didn't support all the timeouts we wanted, and it doesn't support cooperative cancellation.
