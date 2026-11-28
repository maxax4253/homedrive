package main

import (
	"encoding/hex"
	"testing"
)

func TestScryptMatchesRFCAndPython(t *testing.T) {
	// RFC 7914 test vector.
	got := hex.EncodeToString(scryptKey([]byte("password"), []byte("NaCl"), 1024, 8, 16, 64))
	want := "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"
	if got != want {
		t.Fatalf("RFC vector: got %s", got)
	}
	// Same settings as the Python server (hashlib.scrypt n=2**14 r=8 p=1 dklen=32).
	got = hex.EncodeToString(scryptKey([]byte("pw"), []byte("salt"), 1<<14, 8, 1, 32))
	if got != pythonPwSalt {
		t.Fatalf("python vector: got %s", got)
	}
	h := hashPassword("hunter22")
	if !verifyPassword("hunter22", h) || verifyPassword("hunter23", h) {
		t.Fatal("hash/verify round trip")
	}
}

func TestTokens(t *testing.T) {
	tok := makeToken("max", 3, "s3cret", 30)
	u, v, ok := checkToken(tok, "s3cret")
	if !ok || u != "max" || v != 3 {
		t.Fatalf("got %v %v %v", u, v, ok)
	}
	if _, _, ok := checkToken(tok, "other"); ok {
		t.Fatal("wrong secret accepted")
	}
	if _, _, ok := checkToken("garbage!", "s3cret"); ok {
		t.Fatal("garbage accepted")
	}
	s := signValue("tok", "k", 60)
	if !checkSignedValue("tok", s, "k") || checkSignedValue("other", s, "k") {
		t.Fatal("signed value")
	}
}

func TestReadsPythonServerValues(t *testing.T) {
	if u, v, ok := checkToken(pythonToken, "s3cret"); !ok || u != "max" || v != 2 {
		t.Fatalf("python token: %v %v %v", u, v, ok)
	}
	if !verifyPassword("python-made", pythonHash) {
		t.Fatal("python password hash")
	}
	if !checkSignedValue("tok123", pythonSigned, "k") {
		t.Fatal("python signed value")
	}
}
