package syncbff

import (
	"context"
	"fmt"
	"net/http"
	"os"
)

const ContainerAppsTLSMode = "container-apps"

func validateTLSMode(config Config) error {
	switch config.TLSMode {
	case "", "direct":
		return nil
	case ContainerAppsTLSMode:
		if config.Development || os.Getenv("CONTAINER_APP_NAME") == "" || os.Getenv("CONTAINER_APP_REVISION") == "" {
			return fmt.Errorf("container-apps TLS mode requires a production Azure Container Apps deployment")
		}
		return nil
	default:
		return fmt.Errorf("unsupported TLS mode")
	}
}

func (s *Server) transportAllowed(r *http.Request, probe bool) bool {
	if s.config.Development {
		return true
	}
	if s.config.TLSMode == ContainerAppsTLSMode {
		// This mode is an explicit deployment trust boundary, not a generic proxy
		// option. ACA's HTTP ingress overwrites this header. Do not expose this
		// listener using a TCP port or to untrusted peers that bypass that ingress.
		values := r.Header.Values("X-Forwarded-Proto")
		return probe || (len(values) == 1 && values[0] == "https")
	}
	// Never accept a forwarded header as evidence of TLS in the default mode.
	return r.TLS != nil
}

// CheckReady reports successful startup initialization and a currently usable
// process configuration. It does not continuously probe Cosmos or OIDC availability.
func (s *Server) CheckReady(ctx context.Context) error {
	return ctx.Err()
}
