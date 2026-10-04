package syncbff

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func (f *directoryFixture) unlink(t *testing.T, account directoryAccount, target identityProofTarget, twoProofs bool) directoryAccount {
	t.Helper()
	last := len(account.IdentityIDs) - 1
	current, currentTarget := 0, f.google
	if twoProofs {
		current, currentTarget = last, f.apple
	}
	session := f.session(account, current)
	raw, err := f.d.begin(context.Background(), &session, "unlink", target, account.IdentityIDs[last])
	if err != nil {
		t.Fatal(err)
	}
	retained := f.store.state.Bindings[account.IdentityIDs[0]].Identity
	independent := f.proof(t, raw, target, retained.Subject)
	reauthentication := independent
	if twoProofs {
		reauthentication = f.proof(t, raw, currentTarget, f.store.state.Bindings[session.IdentityID].Identity.Subject)
	}
	result, err := f.d.change(context.Background(), session, raw, "unlink", reauthentication, independent)
	if err != nil || result.Account != account.Account || len(result.IdentityIDs) != last {
		t.Fatalf("reserved unlink failed or changed ownership: result=%+v err=%v", result, err)
	}
	if f.store.state.Bindings[account.IdentityIDs[last]].Active {
		t.Fatal("reserved unlink lost its ownership tombstone")
	}
	return result
}

func TestIdentityDirectoryNormalChallengesLeaveUnlinkSlotAndExpireSafely(t *testing.T) {
	f := newDirectoryFixture(t)
	account := f.link(t, f.register(t, f.google, "owner"), "extra")
	session := f.session(account, 0)
	for range maxNormalIdentityChallenges {
		if _, err := f.d.begin(context.Background(), &session, "link", f.apple, ""); err != nil {
			t.Fatal(err)
		}
	}
	_, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
	requireAuthorizationCode(t, err, "identity_challenge_limit")
	raw, err := f.d.begin(context.Background(), &session, "unlink", f.google, account.IdentityIDs[1])
	if err != nil {
		t.Fatal("normal challenges consumed the security slot:", err)
	}
	old := f.proof(t, raw, f.google, "owner")
	audits, proofs, bindings := append([]directoryAudit(nil), f.store.state.Audits...), f.store.state.Proofs, f.store.state.Bindings
	f.now = f.now.Add(identityChallengeLifetime)
	fresh, err := f.d.begin(context.Background(), &session, "unlink", f.google, account.IdentityIDs[1])
	if err != nil {
		t.Fatal(err)
	}
	if len(f.store.state.Challenges) != len(audits)+1 || !reflect.DeepEqual(audits, f.store.state.Audits) ||
		!reflect.DeepEqual(proofs, f.store.state.Proofs) || !reflect.DeepEqual(bindings, f.store.state.Bindings) {
		t.Fatal("expiry cleanup removed consumed challenges, proofs, audit or ownership")
	}
	writes := f.store.writes
	_, err = f.d.change(context.Background(), session, raw, "unlink", old, old)
	requireAuthorizationCode(t, err, "identity_challenge_invalid")
	if f.store.writes != writes {
		t.Fatal("expired nonce partially committed")
	}
	proof := f.proof(t, fresh, f.google, "owner")
	if _, err := f.d.change(context.Background(), session, fresh, "unlink", proof, proof); err != nil {
		t.Fatal(err)
	}
}

func TestIdentityDirectoryReservesEveryUnlinkAtRevisionAndGenerationLimit(t *testing.T) {
	for _, boundary := range []string{"revision", "generation"} {
		t.Run(boundary, func(t *testing.T) {
			f := newDirectoryFixture(t)
			account := f.register(t, f.google, "owner")
			credentials := maxAccountIdentities
			if boundary == "generation" {
				credentials = 4
			}
			for i := 1; i < credentials; i++ {
				account = f.link(t, account, fmt.Sprint(i))
			}
			extra := int64(len(account.IdentityIDs) - 1)
			if boundary == "revision" {
				f.store.state.Revision = maxIdentityGeneration - 2*extra
			} else {
				account.Generation = maxIdentityGeneration - extra
				f.store.state.Accounts[account.AccountID] = account
			}
			session := f.session(account, 0)
			before, writes := cloneTestDirectory(f.store.state), f.store.writes
			raw, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
			if boundary == "revision" {
				requireAuthorizationCode(t, err, "identity_directory_capacity_exceeded")
				if !reflect.DeepEqual(before, f.store.state) || writes != f.store.writes {
					t.Fatal("normal admission spent reserved revisions")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				before, writes = cloneTestDirectory(f.store.state), f.store.writes
				_, err = f.d.change(context.Background(), session, raw, "link",
					f.proof(t, raw, f.google, "owner"), f.proof(t, raw, f.apple, "overflow-generation"))
				requireAuthorizationCode(t, err, "identity_directory_capacity_exceeded")
				if !reflect.DeepEqual(before, f.store.state) || writes != f.store.writes {
					t.Fatal("normal link spent reserved account generations")
				}
			}
			for len(account.IdentityIDs) > 1 {
				account = f.unlink(t, account, f.google, true)
			}
			if boundary == "revision" && f.store.state.Revision != maxIdentityGeneration ||
				boundary == "generation" && account.Generation != maxIdentityGeneration {
				t.Fatal("test did not reach the exact reserved counter boundary")
			}
		})
	}
}

func TestIdentityDirectoryPendingChallengesCannotDoubleSpendCounterReservation(t *testing.T) {
	f := newDirectoryFixture(t)
	account := f.register(t, f.google, "owner")
	for i := 1; i < maxAccountIdentities; i++ {
		account = f.link(t, account, fmt.Sprint(i))
	}
	session := f.session(account, 0)
	raw, err := f.d.begin(context.Background(), &session, "unlink", f.google, account.IdentityIDs[1])
	if err != nil {
		t.Fatal(err)
	}
	other, err := f.d.begin(context.Background(), &session, "unlink", f.google, account.IdentityIDs[2])
	if err != nil {
		t.Fatal(err)
	}
	f.store.state.Revision = maxIdentityGeneration - 2*int64(len(account.IdentityIDs)-1) + 1
	before, writes := cloneTestDirectory(f.store.state), f.store.writes
	_, err = f.d.begin(context.Background(), &session, "unlink", f.google, account.IdentityIDs[3])
	requireAuthorizationCode(t, err, "identity_directory_capacity_exceeded")
	if !reflect.DeepEqual(before, f.store.state) || writes != f.store.writes {
		t.Fatal("another pending challenge double-spent the generation reservation")
	}
	proof := f.proof(t, raw, f.google, "owner")
	account, err = f.d.change(context.Background(), session, raw, "unlink", proof, proof)
	if err != nil {
		t.Fatal(err)
	}
	newSession := f.session(account, 0)
	proof = f.proof(t, other, f.google, "owner")
	_, err = f.d.change(context.Background(), newSession, other, "unlink", proof, proof)
	requireAuthorizationCode(t, err, "identity_challenge_invalid")
	for len(account.IdentityIDs) > 1 {
		account = f.unlink(t, account, f.google, true)
	}
	if f.store.state.Revision != maxIdentityGeneration {
		t.Fatal("reserved path did not reach the exact revision boundary")
	}
}

func TestIdentityDirectoryReservationIsIndependentForEachAccount(t *testing.T) {
	f := newDirectoryFixture(t)
	first := f.link(t, f.link(t, f.register(t, f.google, "first"), "first-extra"), "first-second-extra")
	second := f.link(t, f.link(t, f.register(t, f.google, "second"), "second-extra"), "second-second-extra")
	f.store.state.Revision = maxIdentityGeneration - 8
	accounts := []directoryAccount{first, second}
	raws := make([]string, len(accounts))
	for i, account := range accounts {
		session := f.session(account, 0)
		raw, err := f.d.begin(context.Background(), &session, "unlink", f.google, account.IdentityIDs[2])
		if err != nil {
			t.Fatal(err)
		}
		raws[i] = raw
	}
	for i, account := range accounts {
		session := f.session(account, 0)
		subject := f.store.state.Bindings[session.IdentityID].Identity.Subject
		proof := f.proof(t, raws[i], f.google, subject)
		var err error
		account, err = f.d.change(context.Background(), session, raws[i], "unlink", proof, proof)
		if err != nil {
			t.Fatal(err)
		}
		accounts[i] = f.unlink(t, account, f.google, false)
	}
	if f.store.state.Revision != maxIdentityGeneration || accounts[0].Account != first.Account ||
		accounts[1].Account != second.Account || len(accounts[0].IdentityIDs) != 1 || len(accounts[1].IdentityIDs) != 1 {
		t.Fatal("one account consumed another account's reserved unlink path or changed ownership")
	}
}

func TestIdentityDirectoryNormalSaturationPreservesAuditProofAndChallengeCapacity(t *testing.T) {
	for _, twoProofs := range []bool{false, true} {
		t.Run(fmt.Sprint("two-proofs=", twoProofs), func(t *testing.T) {
			f := newDirectoryFixture(t)
			account := f.register(t, f.google, "owner")
			for i := 1; i < maxAccountIdentities; i++ {
				account = f.link(t, account, fmt.Sprint(i))
			}
			rejected := false
			for i := range maxIdentityAudits {
				account = f.unlink(t, account, f.google, twoProofs)
				session := f.session(account, 0)
				raw, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
				if err == nil {
					before, writes := cloneTestDirectory(f.store.state), f.store.writes
					var result directoryAccount
					result, err = f.d.change(context.Background(), session, raw, "link",
						f.proof(t, raw, f.google, "owner"), f.proof(t, raw, f.apple, fmt.Sprint("cycle-", i)))
					if err == nil {
						account = result
						continue
					}
					if !reflect.DeepEqual(before, f.store.state) || writes != f.store.writes {
						t.Fatal("failed capacity admission partially changed ownership or replay metadata")
					}
				}
				requireAuthorizationCode(t, err, "identity_directory_capacity_exceeded")
				rejected = true
				break
			}
			extra := len(account.IdentityIDs) - 1
			if !rejected || extra == 0 {
				t.Fatal("normal operations did not reach a capacity boundary with credentials still removable")
			}
			if twoProofs {
				if occupied := len(f.store.state.Proofs) + 2*extra; occupied < maxIdentityProofs-3 || occupied > maxIdentityProofs {
					t.Fatalf("did not measure the proof boundary: %d", occupied)
				}
			} else if occupied := len(f.store.state.Audits) + extra; occupied < maxIdentityAudits-1 || occupied > maxIdentityAudits {
				t.Fatalf("did not measure the audit boundary: %d", occupied)
			}
			for len(account.IdentityIDs) > 1 {
				account = f.unlink(t, account, f.google, twoProofs)
			}
			if len(f.store.state.Proofs) > maxIdentityProofs || len(f.store.state.Audits) > maxIdentityAudits ||
				len(f.store.state.Challenges) > maxIdentityChallenges || !validIdentityDirectory(f.store.state) {
				t.Fatal("security reservation exceeded a physical metadata limit")
			}
		})
	}
}

func TestIdentityDirectoryReservesSerializedBytesForLargestApprovedCallback(t *testing.T) {
	f := newDirectoryFixture(t)
	target := f.google
	target.Callback = "https://callback.invalid/" + strings.Repeat("<", 2000)
	f.d.targets[target] = true
	account := f.register(t, f.google, "owner")
	for i := 1; i < maxAccountIdentities; i++ {
		account = f.link(t, account, fmt.Sprint(i))
	}
	rejected := false
	for range maxIdentityChallenges {
		before, writes := cloneTestDirectory(f.store.state), f.store.writes
		_, err := f.d.begin(context.Background(), nil, "register", target, "")
		if err == nil {
			continue
		}
		requireAuthorizationCode(t, err, "identity_directory_capacity_exceeded")
		if !reflect.DeepEqual(before, f.store.state) || writes != f.store.writes {
			t.Fatal("byte-capacity rejection partially wrote")
		}
		rejected = true
		break
	}
	if !rejected || len(f.store.state.Challenges) >= maxIdentityChallenges {
		t.Fatal("test did not reach serialized byte capacity before the row limit")
	}
	for len(account.IdentityIDs) > 1 {
		account = f.unlink(t, account, target, false)
	}
	body, err := encodeJSON(f.store.state)
	if err != nil || len(body) > maxIdentityDirectoryBytes || !validIdentityDirectory(f.store.state) {
		t.Fatal("largest approved callback exceeded the physical serialized bound")
	}
}
