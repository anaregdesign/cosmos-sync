package syncbff

import (
	"context"
	"crypto/sha256"
	"encoding/json"
)

type observedIdentityDirectory struct {
	revision int64
	digest   [32]byte
}

func observeIdentityDirectory(ctx context.Context, state *identityDirectoryState) error {
	sessions, ok := ctx.Value(authorizationSessionsKey{}).(*authorizationSessions)
	if !ok {
		return nil
	}
	var current observedIdentityDirectory
	if state != nil {
		if !validIdentityDirectory(state) {
			return protocolError(503, "identity_directory_unavailable")
		}
		body, err := encodeJSON(state)
		if err != nil {
			return protocolError(503, "identity_directory_unavailable")
		}
		current = observedIdentityDirectory{revision: state.Revision, digest: sha256.Sum256(body)}
	}
	sessions.mu.Lock()
	defer sessions.mu.Unlock()
	previous := sessions.directory
	if previous != nil && (state == nil || current.revision < previous.revision ||
		current.revision == previous.revision && current.digest != previous.digest) {
		return protocolError(503, "identity_directory_unavailable")
	}
	if state != nil {
		sessions.directory = &current
	}
	return nil
}

func cloneIdentityDirectory(state *identityDirectoryState) (*identityDirectoryState, error) {
	if state == nil {
		return nil, nil
	}
	body, err := encodeJSON(state)
	if err != nil {
		return nil, protocolError(503, "identity_directory_unavailable")
	}
	var copy identityDirectoryState
	if json.Unmarshal(body, &copy) != nil {
		return nil, protocolError(503, "identity_directory_unavailable")
	}
	return &copy, nil
}

func (d *identityDirectory) load(ctx context.Context) (*identityDirectoryState, string, error) {
	state, version, err := d.store.loadIdentityDirectory(ctx)
	if err != nil {
		return nil, "", err
	}
	if (state == nil) != (version == "") {
		return nil, "", protocolError(503, "identity_directory_unavailable")
	}
	if err := observeIdentityDirectory(ctx, state); err != nil {
		return nil, "", err
	}
	return state, version, nil
}
