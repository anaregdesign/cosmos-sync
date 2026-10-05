package syncbff

import (
	"context"
	"strconv"
)

type memoryIdentityDirectoryStore struct{ memory *MemoryStore }

func (s memoryIdentityDirectoryStore) loadIdentityDirectory(ctx context.Context) (*identityDirectoryState, string, error) {
	if err := ctx.Err(); err != nil {
		return nil, "", err
	}
	s.memory.mu.Lock()
	defer s.memory.mu.Unlock()
	state, err := cloneIdentityDirectory(s.memory.identityDirectory)
	if err != nil || state == nil {
		return nil, "", err
	}
	return state, strconv.FormatUint(s.memory.identityVersion, 10), nil
}

func (s memoryIdentityDirectoryStore) compareIdentityDirectory(ctx context.Context, version string, state *identityDirectoryState) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if !validIdentityDirectory(state) {
		return protocolError(503, "identity_directory_unavailable")
	}
	copy, err := cloneIdentityDirectory(state)
	if err != nil {
		return err
	}
	s.memory.mu.Lock()
	defer s.memory.mu.Unlock()
	expected := ""
	if s.memory.identityDirectory != nil {
		expected = strconv.FormatUint(s.memory.identityVersion, 10)
	}
	if version != expected {
		return protocolError(412, "authorization_contention")
	}
	s.memory.identityDirectory, s.memory.identityVersion = copy, s.memory.identityVersion+1
	return nil
}
