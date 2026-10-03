package main

import (
	"context"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

func main() {
	configFile := flag.String("config", "config.json", "server configuration JSON; secrets may be supplied by environment")
	flag.Parse()
	explicitFile := false
	flag.Visit(func(f *flag.Flag) { explicitFile = explicitFile || f.Name == "config" })
	cfg, err := readConfiguration(*configFile, explicitFile, os.LookupEnv)
	if err != nil {
		log.Fatal(err)
	}
	if value := os.Getenv("COSMOS_SYNC_CURSOR_KEY_BASE64"); value != "" {
		cfg.CursorKeyBase64 = value
	}
	cfg.MetricsToken = os.Getenv("COSMOS_SYNC_METRICS_TOKEN")
	cfg.TLSMode = os.Getenv("COSMOS_SYNC_TLS_MODE")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	verifier, err := syncbff.NewOIDCVerifier(ctx, cfg.OIDC)
	if err != nil {
		log.Fatal("OIDC discovery failed: ", err)
	}
	var store syncbff.Store
	if cfg.Storage == "memory" {
		if !cfg.Development {
			log.Fatal("memory store requires development=true")
		}
		store = syncbff.NewMemoryStore()
	} else if cfg.Storage == "cosmos" {
		cosmos, err := syncbff.NewCosmosStore(ctx, cfg.Cosmos)
		if err != nil {
			log.Fatal("Cosmos initialization failed: ", err)
		}
		defer cosmos.Close()
		store = cosmos
	} else {
		log.Fatal("storage must be cosmos or memory")
	}
	handler, err := syncbff.NewServer(cfg, store, verifier)
	if err != nil {
		log.Fatal(err)
	}
	if handler.CheckReady(ctx) != nil {
		log.Fatal("server readiness initialization failed")
	}
	if cfg.Listen == "" {
		if cfg.Development {
			cfg.Listen = "127.0.0.1:8080"
		} else {
			cfg.Listen = ":8080"
		}
	}
	if cfg.Development {
		host, _, err := net.SplitHostPort(cfg.Listen)
		ip := net.ParseIP(host)
		if err != nil || (host != "localhost" && (ip == nil || !ip.IsLoopback())) {
			log.Fatal("development listener must use a loopback address")
		}
	}
	server := &http.Server{Addr: cfg.Listen, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32768}
	stop, shutdown := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer shutdown()
	log.Print("Cosmos Sync BFF listening on ", cfg.Listen)
	// Direct TLS is the default. ACA mode explicitly trusts the platform's HTTP
	// ingress and never enables a generic forwarded-header option.
	cert, key := os.Getenv("COSMOS_SYNC_TLS_CERT"), os.Getenv("COSMOS_SYNC_TLS_KEY")
	if (cert == "") != (key == "") {
		log.Fatal("TLS certificate and key must be configured together")
	}
	if cfg.TLSMode == syncbff.ContainerAppsTLSMode && (cert != "" || key != "") {
		log.Fatal("container-apps TLS mode cannot use direct TLS certificate settings")
	}
	if !cfg.Development && cfg.TLSMode != syncbff.ContainerAppsTLSMode && (cert == "" || key == "") {
		log.Fatal("production requires COSMOS_SYNC_TLS_CERT and COSMOS_SYNC_TLS_KEY")
	}
	err = serveWithShutdown(stop, server, func() error {
		if cert != "" && key != "" {
			return server.ListenAndServeTLS(cert, key)
		}
		return server.ListenAndServe()
	})
	if err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
