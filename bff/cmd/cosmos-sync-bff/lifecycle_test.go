package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"
)

type shutdownObservedListener struct {
	net.Listener
	once   sync.Once
	closed chan struct{}
}

func (l *shutdownObservedListener) Close() error {
	err := l.Listener.Close()
	l.once.Do(func() { close(l.closed) })
	return err
}

func TestShutdownWaitsForActiveRequestBeforeReturning(t *testing.T) {
	baseListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listener := &shutdownObservedListener{Listener: baseListener, closed: make(chan struct{})}
	entered, release := make(chan struct{}), make(chan struct{})
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-release
		_, _ = w.Write([]byte("drained"))
	})}
	t.Cleanup(func() { _ = server.Close() })
	stop, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- serveWithShutdown(stop, server, func() error { return server.Serve(listener) }) }()
	requestDone := make(chan error, 1)
	go func() {
		client := &http.Client{Timeout: 3 * time.Second}
		response, err := client.Get("http://" + listener.Addr().String())
		if err == nil {
			_, err = io.ReadAll(response.Body)
			_ = response.Body.Close()
		}
		requestDone <- err
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("request did not enter handler")
	}
	cancel()
	select {
	case <-listener.closed:
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown did not close its listener")
	}
	select {
	case <-done:
		t.Fatal("process lifecycle returned before draining active request")
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	select {
	case err := <-requestDone:
		if err != nil {
			t.Fatalf("active request was not drained: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("active request did not finish")
	}
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			t.Fatal("unexpected lifecycle result")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown did not complete")
	}
}

func TestStartupFailureDoesNotLeaveShutdownWaiter(t *testing.T) {
	want := errors.New("listen failed")
	done := make(chan error, 1)
	go func() { done <- serveWithShutdown(context.Background(), &http.Server{}, func() error { return want }) }()
	select {
	case got := <-done:
		if !errors.Is(got, want) {
			t.Fatal("startup error was lost")
		}
	case <-time.After(time.Second):
		t.Fatal("startup failure left a waiting shutdown goroutine")
	}
}
