package main

// Passwords, login tokens and short-lived signed values.
//
// Everything here matches the Python server byte for byte, so existing accounts,
// saved logins in the Mac app and password-protected share links keep working
// after moving to this server.

import (
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/bits"
	"strconv"
	"strings"
	"time"
)

// ---------------------------------------------------------------- scrypt (RFC 7914)

const (
	scryptN      = 1 << 14
	scryptR      = 8
	scryptP      = 1
	scryptKeyLen = 32
)

func salsa208(b *[16]uint32) {
	x := *b
	for i := 0; i < 8; i += 2 {
		x[4] ^= bits.RotateLeft32(x[0]+x[12], 7)
		x[8] ^= bits.RotateLeft32(x[4]+x[0], 9)
		x[12] ^= bits.RotateLeft32(x[8]+x[4], 13)
		x[0] ^= bits.RotateLeft32(x[12]+x[8], 18)
		x[9] ^= bits.RotateLeft32(x[5]+x[1], 7)
		x[13] ^= bits.RotateLeft32(x[9]+x[5], 9)
		x[1] ^= bits.RotateLeft32(x[13]+x[9], 13)
		x[5] ^= bits.RotateLeft32(x[1]+x[13], 18)
		x[14] ^= bits.RotateLeft32(x[10]+x[6], 7)
		x[2] ^= bits.RotateLeft32(x[14]+x[10], 9)
		x[6] ^= bits.RotateLeft32(x[2]+x[14], 13)
		x[10] ^= bits.RotateLeft32(x[6]+x[2], 18)
		x[3] ^= bits.RotateLeft32(x[15]+x[11], 7)
		x[7] ^= bits.RotateLeft32(x[3]+x[15], 9)
		x[11] ^= bits.RotateLeft32(x[7]+x[3], 13)
		x[15] ^= bits.RotateLeft32(x[11]+x[7], 18)
		x[1] ^= bits.RotateLeft32(x[0]+x[3], 7)
		x[2] ^= bits.RotateLeft32(x[1]+x[0], 9)
		x[3] ^= bits.RotateLeft32(x[2]+x[1], 13)
		x[0] ^= bits.RotateLeft32(x[3]+x[2], 18)
		x[6] ^= bits.RotateLeft32(x[5]+x[4], 7)
		x[7] ^= bits.RotateLeft32(x[6]+x[5], 9)
		x[4] ^= bits.RotateLeft32(x[7]+x[6], 13)
		x[5] ^= bits.RotateLeft32(x[4]+x[7], 18)
		x[11] ^= bits.RotateLeft32(x[10]+x[9], 7)
		x[8] ^= bits.RotateLeft32(x[11]+x[10], 9)
		x[9] ^= bits.RotateLeft32(x[8]+x[11], 13)
		x[10] ^= bits.RotateLeft32(x[9]+x[8], 18)
		x[12] ^= bits.RotateLeft32(x[15]+x[14], 7)
		x[13] ^= bits.RotateLeft32(x[12]+x[15], 9)
		x[14] ^= bits.RotateLeft32(x[13]+x[12], 13)
		x[15] ^= bits.RotateLeft32(x[14]+x[13], 18)
	}
	for i := range b {
		b[i] += x[i]
	}
}

// blockMix: B (2r blocks of 16 words) -> Y, using salsa20/8.
func blockMix(b, y []uint32, r int) {
	var x [16]uint32
	copy(x[:], b[(2*r-1)*16:])
	for i := 0; i < 2*r; i++ {
		for j := 0; j < 16; j++ {
			x[j] ^= b[i*16+j]
		}
		salsa208(&x)
		// Even blocks go to the first half, odd blocks to the second half.
		dst := (i/2)*16 + (i%2)*r*16
		copy(y[dst:dst+16], x[:])
	}
}

func roMix(b []byte, r, n int) {
	words := 32 * r
	x := make([]uint32, words)
	y := make([]uint32, words)
	v := make([]uint32, words*n)
	for i := range x {
		x[i] = binary.LittleEndian.Uint32(b[i*4:])
	}
	for i := 0; i < n; i++ {
		copy(v[i*words:], x)
		blockMix(x, y, r)
		x, y = y, x
	}
	for i := 0; i < n; i++ {
		j := int(x[(2*r-1)*16] & uint32(n-1))
		for k := range x {
			x[k] ^= v[j*words+k]
		}
		blockMix(x, y, r)
		x, y = y, x
	}
	for i := range x {
		binary.LittleEndian.PutUint32(b[i*4:], x[i])
	}
}

func scryptKey(password, salt []byte, n, r, p, keyLen int) []byte {
	b, _ := pbkdf2.Key(sha256.New, string(password), salt, 1, p*128*r)
	for i := 0; i < p; i++ {
		roMix(b[i*128*r:(i+1)*128*r], r, n)
	}
	out, _ := pbkdf2.Key(sha256.New, string(password), b, 1, keyLen)
	return out
}

func hashPassword(password string) string {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	digest := scryptKey([]byte(password), salt, scryptN, scryptR, scryptP, scryptKeyLen)
	return "scrypt$" + hex.EncodeToString(salt) + "$" + hex.EncodeToString(digest)
}

func verifyPassword(password, stored string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 3 || parts[0] != "scrypt" {
		return false
	}
	salt, err1 := hex.DecodeString(parts[1])
	want, err2 := hex.DecodeString(parts[2])
	if err1 != nil || err2 != nil {
		return false
	}
	got := scryptKey([]byte(password), salt, scryptN, scryptR, scryptP, len(want))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// ---------------------------------------------------------------- tokens

func sign(payload, secret string) string {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(payload))
	return hex.EncodeToString(m.Sum(nil))
}

// makeToken: base64url("username:version:expires:signature"), same as the Python server.
func makeToken(username string, version int, secret string, days int) string {
	expires := time.Now().Unix() + int64(days)*86400
	payload := fmt.Sprintf("%s:%d:%d", username, version, expires)
	return base64.URLEncoding.EncodeToString([]byte(payload + ":" + sign(payload, secret)))
}

// checkToken returns the username and token version if the token is genuine and current.
func checkToken(token, secret string) (string, int, bool) {
	raw, err := base64.URLEncoding.DecodeString(token)
	if err != nil {
		if raw, err = base64.RawURLEncoding.DecodeString(token); err != nil {
			return "", 0, false
		}
	}
	parts := strings.Split(string(raw), ":")
	if len(parts) < 4 {
		return "", 0, false
	}
	sig := parts[len(parts)-1]
	expires, version := parts[len(parts)-2], parts[len(parts)-3]
	username := strings.Join(parts[:len(parts)-3], ":")
	v, err1 := strconv.Atoi(version)
	exp, err2 := strconv.ParseInt(expires, 10, 64)
	if err1 != nil || err2 != nil {
		return "", 0, false
	}
	want := sign(username+":"+version+":"+expires, secret)
	if !hmac.Equal([]byte(sig), []byte(want)) || exp < time.Now().Unix() {
		return "", 0, false
	}
	return username, v, true
}

// signValue: a short-lived "expires.signature" code, e.g. "this visitor entered the link password".
func signValue(value, secret string, seconds int) string {
	expires := time.Now().Unix() + int64(seconds)
	return fmt.Sprintf("%d.%s", expires, sign(fmt.Sprintf("%s:%d", value, expires), secret)[:32])
}

func checkSignedValue(value, signed, secret string) bool {
	expStr, sig, ok := strings.Cut(signed, ".")
	if !ok {
		return false
	}
	exp, err := strconv.ParseInt(expStr, 10, 64)
	if err != nil || exp < time.Now().Unix() {
		return false
	}
	want := sign(value+":"+expStr, secret)[:32]
	return hmac.Equal([]byte(sig), []byte(want))
}

func randomToken(nBytes int) string {
	b := make([]byte, nBytes)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func randomHex(nBytes int) string {
	b := make([]byte, nBytes)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
