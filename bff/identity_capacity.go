package syncbff

import (
	"strconv"
	"strings"
	"time"
)

func identityCounterPadding(value int64) int {
	return len(strconv.FormatInt(maxIdentityGeneration, 10)) - len(strconv.FormatInt(value, 10))
}

func (d *identityDirectory) unlinkCapacityBytes() (int, int, error) {
	id := strings.Repeat("f", 64)
	now := time.Unix(1800000000, 0).UTC()
	largestChallenge := 0
	for target := range d.targets {
		body, err := encodeJSON(map[string]directoryChallenge{id: {
			AccountID: id, Generation: maxIdentityGeneration, Operation: "unlink", Target: target,
			RemoveIdentityID: id, IssuedAt: now, ExpiresAt: now.Add(identityChallengeLifetime),
		}})
		if err != nil {
			return 0, 0, protocolError(503, "identity_directory_unavailable")
		}
		largestChallenge = max(largestChallenge, len(body)-1)
	}
	audit, err := encodeJSON(directoryAudit{
		AccountID: id, IdentityID: id, Generation: maxIdentityGeneration, Operation: "unlink",
		ChallengeDigest: id, ProofDigests: []string{id, id}, OccurredAt: now,
	})
	if err != nil {
		return 0, 0, protocolError(503, "identity_directory_unavailable")
	}
	proofs, err := encodeJSON(map[string]string{id: id, strings.Repeat("e", 64): id})
	if err != nil {
		return 0, 0, protocolError(503, "identity_directory_unavailable")
	}
	return largestChallenge, len(audit) + 1 + len(proofs), nil
}

func (d *identityDirectory) checkSecurityCapacity(state *identityDirectoryState, now time.Time) error {
	remaining := 0
	padding := identityCounterPadding(state.Revision)
	for _, account := range state.Accounts {
		extra := len(account.IdentityIDs) - 1
		if account.Generation+int64(extra) > maxIdentityGeneration {
			return protocolError(507, "identity_directory_capacity_exceeded")
		}
		remaining += extra
		padding += identityCounterPadding(account.Generation)
	}
	pending := make(map[string]int)
	for digest, challenge := range state.Challenges {
		padding += identityCounterPadding(challenge.Generation)
		account, exists := state.Accounts[challenge.AccountID]
		if !exists || len(account.IdentityIDs) <= 1 || challenge.Consumed || challenge.Operation != "unlink" ||
			challenge.Generation != account.Generation || !challenge.ExpiresAt.After(now) {
			continue
		}
		binding := state.Bindings[challenge.RemoveIdentityID]
		if !binding.Active {
			continue
		}
		body, err := encodeJSON(map[string]directoryChallenge{digest: challenge})
		if err != nil {
			return protocolError(503, "identity_directory_unavailable")
		}
		credit := len(body) - 1 + identityCounterPadding(challenge.Generation)
		// One unlink changes the generation and invalidates this account's
		// other challenges. Credit only its smallest already-allocated challenge.
		if previous, exists := pending[challenge.AccountID]; !exists || credit < previous {
			pending[challenge.AccountID] = credit
		}
	}
	for _, audit := range state.Audits {
		padding += identityCounterPadding(audit.Generation)
	}
	if state.Revision+int64(2*remaining-len(pending)) > maxIdentityGeneration ||
		len(state.Challenges)+remaining-len(pending) > maxIdentityChallenges ||
		len(state.Proofs)+2*remaining > maxIdentityProofs || len(state.Audits)+remaining > maxIdentityAudits {
		return protocolError(507, "identity_directory_capacity_exceeded")
	}
	challengeBytes, transactionBytes, err := d.unlinkCapacityBytes()
	if err != nil {
		return err
	}
	body, err := encodeJSON(state)
	if err != nil {
		return protocolError(503, "identity_directory_unavailable")
	}
	reservedBytes := remaining * (challengeBytes + transactionBytes)
	for _, credit := range pending {
		reservedBytes -= credit
	}
	// Charge all counters at their maximum width, including allocated
	// challenges/audits, so digit growth cannot consume a security reservation.
	if len(body)+padding+reservedBytes > maxIdentityDirectoryBytes {
		return protocolError(507, "identity_directory_capacity_exceeded")
	}
	return nil
}
