package main

import (
	"context"
	"net/http"
	"time"
)

// Wait for bounded draining before main returns. ListenAndServe itself returns
// as soon as Shutdown closes the listener, while active requests may remain.
func serveWithShutdown(stop context.Context, server *http.Server, serve func() error) error {
	servingDone := make(chan struct{})
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		select {
		case <-stop.Done():
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if server.Shutdown(ctx) != nil {
				// Forced closure bounds a long-lived stream to the grace period.
				_ = server.Close()
			}
		case <-servingDone:
		}
	}()
	err := serve()
	close(servingDone)
	<-shutdownDone
	return err
}
